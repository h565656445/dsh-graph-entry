$ErrorActionPreference = 'Stop'

# Pester 5 兼容化：初始化与辅助函数移入 BeforeAll（Discovery/Run 作用域隔离），
# 候选验证经 HERMES_HARNESS_ROOT 注入真实项目根；晋级后 $PSScriptRoot 兜底，行为等价。
BeforeAll {

# GraphEntry 发现入口定点测试（Pester 3.4 语义）。
# 被测脚本路径可由环境变量 GRAPH_ENTRY_TEST_TARGET 覆写，
# 注册表权威源可由 GRAPH_ENTRY_REGISTRY_SOURCE 覆写，
# 用于候选树验证：证明测试进程实际加载的是候选文件（铁律 11）。
$script:GraphEntryPath = $env:GRAPH_ENTRY_TEST_TARGET
if (-not $script:GraphEntryPath) {
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $script:GraphEntryPath = Join-Path $projectRoot 'runner\graph_entry.ps1'
}

$script:RegistrySourcePath = $env:GRAPH_ENTRY_REGISTRY_SOURCE
if (-not $script:RegistrySourcePath) {
    $fallbackProjectRoot = Split-Path -Parent $PSScriptRoot
    $fallbackVaultRoot = Split-Path -Parent (Split-Path -Parent $fallbackProjectRoot)
    $script:RegistrySourcePath = Join-Path $fallbackVaultRoot '00-系统\项目注册表.md'
}

function Invoke-GraphEntryProcess {
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    $fullArgs = @($ArgumentList) + @('-RegistrySourcePath', $script:RegistrySourcePath)
    $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $script:GraphEntryPath @fullArgs 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output -join "`n")
    }
}

function New-TestRuntimeWithTask {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [string]$ContractState = 'routed',
        [string[]]$LedgerLines = @()
    )

    $runtime = Join-Path $TestDrive ('rt_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $taskDir = Join-Path $runtime ('tasks\' + $TaskId)
    New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $taskDir 'contract.json') -Value ('{"state":"' + $ContractState + '"}') -Encoding utf8

    $ledgerPath = Join-Path $runtime 'task_ledger.jsonl'
    $body = ($LedgerLines -join "`r`n")
    $content = if ($LedgerLines.Count -gt 0) { ([char]0xFEFF).ToString() + $body + "`r`n" } else { '' }
    [System.IO.File]::WriteAllText($ledgerPath, $content, [System.Text.UTF8Encoding]::new($false))
    return $runtime
}

function New-LedgerLine {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Event,
        [string]$State = 'routed',
        [int]$Seq = 0,
        [string]$Timestamp = '2026-07-17T02:06:59.0000000+08:00'
    )

    return ('{"timestamp":"' + $Timestamp + '","task_id":"' + $TaskId + '","state":"' + $State + '","event":"' + $Event + '","details":{"seq":' + $Seq + '}}')
}

function New-TestRegistrySource {
    param([Parameter(Mandatory)][string]$RootPath)

    $sourcePath = Join-Path $TestDrive ('项目注册表_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.md')
    # 缺口样例与停摆样例根路径：TestDrive 沙箱内的受控路径且故意不创建，
    # 不再依赖沙箱外绝对路径，fixture 完全可复现。
    $gapRoot = Join-Path $TestDrive 'health_gap_missing_root'
    $archivedRoot = Join-Path $TestDrive 'health_archived_root'
    $table = @(
        '| 项目 | 状态 | 根目录 | 项目记忆 | 主要目标 |',
        '| --- | --- | --- | --- | --- |',
        ('| 健康样例 | active | `' + $RootPath + '` | `00_项目记忆` | 健康检查样例 |'),
        ('| 缺口样例 | active | `' + $gapRoot + '` | `00_项目记忆` | 入口缺口样例 |'),
        ('| 停摆样例 | archived | `' + $archivedRoot + '` | `00_项目记忆` | 非活动项目 |')
    ) -join "`r`n"
    Set-Content -LiteralPath $sourcePath -Value $table -Encoding utf8
    return $sourcePath
}

function New-HealthFixture {
    # health 分支统一 fixture：健康项目根（含 AGENTS.md）+ fixture 注册表源。
    # 调用方负责将 $script:RegistrySourcePath 指向返回的 RegistrySource 并在 finally 中恢复。
    $healthyRoot = Join-Path $TestDrive ('healthy_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $healthyRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $healthyRoot 'AGENTS.md') -Value '# healthy' -Encoding utf8
    return [pscustomobject]@{
        HealthyRoot    = $healthyRoot
        RegistrySource = (New-TestRegistrySource -RootPath $healthyRoot)
    }
}

}

Describe 'GraphEntry discovery entry baseline' {

    Context 'subject=projects' {
        It 'returns ok:true drift:false with a non-empty project list and registry hash' {
            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', 'projects', '-AsJson')
            $result.ExitCode | Should -Be 0
            $payload = $result.Output | ConvertFrom-Json
            $payload.ok | Should -Be $true
            $payload.drift | Should -Be $false
            $payload.subject | Should -Be 'projects'
            $payload.schema_version | Should -Be '1.0'
            $payload.registry_source_sha256 | Should -Not -BeNullOrEmpty
            @($payload.projects).Count | Should -BeGreaterThan 0
            foreach ($project in @($payload.projects)) {
                $project.root_path | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'subject=task:<id>' {
        It 'returns contract state and the last matching ledger event for the task' {
            $taskId = 'task-20260701-000000-aaaaaaaa'
            $runtime = New-TestRuntimeWithTask -TaskId $taskId -ContractState 'waiting_for_user' -LedgerLines @(
                (New-LedgerLine -TaskId $taskId -Event 'contract_created' -State 'routed' -Seq 1),
                (New-LedgerLine -TaskId 'task-20260702-000000-bbbbbbbb' -Event 'contract_created' -State 'routed' -Seq 2),
                (New-LedgerLine -TaskId $taskId -Event 'worker_dispatched' -State 'executing' -Seq 3),
                (New-LedgerLine -TaskId 'task-20260702-000000-bbbbbbbb' -Event 'worker_ready' -State 'routed' -Seq 4)
            )

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('task:' + $taskId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 0
            $payload = $result.Output | ConvertFrom-Json
            $payload.ok | Should -Be $true
            $payload.schema_version | Should -Be '1.0'
            $payload.task_id | Should -Be $taskId
            $payload.state | Should -Be 'waiting_for_user'
            $payload.latest_ledger_event.event | Should -Be 'worker_dispatched'
            $payload.latest_ledger_event.details.seq | Should -Be 3
        }

        It 'keeps last-file-order matching semantics when the task appears many times' {
            $taskId = 'task-20260701-000000-aaaaaaaa'
            $runtime = New-TestRuntimeWithTask -TaskId $taskId -LedgerLines @(
                (New-LedgerLine -TaskId $taskId -Event 'contract_created' -State 'routed' -Seq 1),
                (New-LedgerLine -TaskId $taskId -Event 'verification_started' -State 'verifying' -Seq 2),
                (New-LedgerLine -TaskId $taskId -Event 'task_archived' -State 'completed' -Seq 3)
            )

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('task:' + $taskId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 0
            $payload = $result.Output | ConvertFrom-Json
            $payload.latest_ledger_event.event | Should -Be 'task_archived'
            $payload.latest_ledger_event.details.seq | Should -Be 3
        }

        It 'returns a null latest event when the ledger has no event for the task' {
            $taskId = 'task-20260701-000000-aaaaaaaa'
            $runtime = New-TestRuntimeWithTask -TaskId $taskId -LedgerLines @(
                (New-LedgerLine -TaskId 'task-20260702-000000-bbbbbbbb' -Event 'contract_created' -Seq 1)
            )

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('task:' + $taskId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 0
            $payload = $result.Output | ConvertFrom-Json
            $payload.latest_ledger_event | Should -BeNullOrEmpty
        }

        It 'treats a missing ledger file as no events instead of failing' {
            $taskId = 'task-20260701-000000-aaaaaaaa'
            $runtime = New-TestRuntimeWithTask -TaskId $taskId
            Remove-Item -LiteralPath (Join-Path $runtime 'task_ledger.jsonl') -Force

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('task:' + $taskId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 0
            $payload = $result.Output | ConvertFrom-Json
            $payload.latest_ledger_event | Should -BeNullOrEmpty
        }

        It 'tolerates a torn tail line and still returns the last complete matching event' {
            $taskId = 'task-20260701-000000-aaaaaaaa'
            $runtime = New-TestRuntimeWithTask -TaskId $taskId -LedgerLines @(
                (New-LedgerLine -TaskId $taskId -Event 'contract_created' -State 'routed' -Seq 1),
                (New-LedgerLine -TaskId $taskId -Event 'worker_dispatched' -State 'executing' -Seq 2)
            )
            $ledgerPath = Join-Path $runtime 'task_ledger.jsonl'
            $bytes = [System.IO.File]::ReadAllBytes($ledgerPath)
            $torn = [System.Text.Encoding]::UTF8.GetBytes('{"timestamp":"2026-07-17T03:00:00+08:00","task_id":"task-2026070')
            $all = New-Object byte[] ($bytes.Length + $torn.Length)
            [Array]::Copy($bytes, 0, $all, 0, $bytes.Length)
            [Array]::Copy($torn, 0, $all, $bytes.Length, $torn.Length)
            [System.IO.File]::WriteAllBytes($ledgerPath, $all)

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('task:' + $taskId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 0
            $payload = $result.Output | ConvertFrom-Json
            $payload.latest_ledger_event.event | Should -Be 'worker_dispatched'
            $payload.latest_ledger_event.details.seq | Should -Be 2
        }

        It 'skips a torn tail line that would have matched the target task' {
            $taskId = 'task-20260701-000000-aaaaaaaa'
            $runtime = New-TestRuntimeWithTask -TaskId $taskId -LedgerLines @(
                (New-LedgerLine -TaskId $taskId -Event 'contract_created' -State 'routed' -Seq 1)
            )
            $ledgerPath = Join-Path $runtime 'task_ledger.jsonl'
            $bytes = [System.IO.File]::ReadAllBytes($ledgerPath)
            $torn = [System.Text.Encoding]::UTF8.GetBytes('{"timestamp":"2026-07-17T03:00:00+08:00","task_id":"task-20260701-000000-aaaaaaaa"')
            $all = New-Object byte[] ($bytes.Length + $torn.Length)
            [Array]::Copy($bytes, 0, $all, 0, $bytes.Length)
            [Array]::Copy($torn, 0, $all, $bytes.Length, $torn.Length)
            [System.IO.File]::WriteAllBytes($ledgerPath, $all)

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('task:' + $taskId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 0
            $payload = $result.Output | ConvertFrom-Json
            $payload.latest_ledger_event.event | Should -Be 'contract_created'
            $payload.latest_ledger_event.details.seq | Should -Be 1
        }

        It 'still returns a later matching event when an earlier line is corrupt' {
            $taskId = 'task-20260701-000000-aaaaaaaa'
            $runtime = New-TestRuntimeWithTask -TaskId $taskId -LedgerLines @(
                (New-LedgerLine -TaskId $taskId -Event 'contract_created' -State 'routed' -Seq 1),
                'not-json-at-all',
                (New-LedgerLine -TaskId $taskId -Event 'worker_dispatched' -State 'executing' -Seq 2)
            )

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('task:' + $taskId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 0
            $payload = $result.Output | ConvertFrom-Json
            $payload.latest_ledger_event.event | Should -Be 'worker_dispatched'
            $payload.latest_ledger_event.details.seq | Should -Be 2
        }

        It 'fails closed when more than one trailing line is unparseable' {
            $taskId = 'task-20260701-000000-aaaaaaaa'
            $runtime = New-TestRuntimeWithTask -TaskId $taskId -LedgerLines @(
                (New-LedgerLine -TaskId $taskId -Event 'contract_created' -State 'routed' -Seq 1),
                'bad-line-one',
                'bad-line-two'
            )

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('task:' + $taskId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 2
            $payload = $result.Output | ConvertFrom-Json
            $payload.ok | Should -Be $false
        }

        It 'ignores blank and whitespace-only ledger lines' {
            $taskId = 'task-20260701-000000-aaaaaaaa'
            $line1 = New-LedgerLine -TaskId $taskId -Event 'contract_created' -State 'routed' -Seq 1
            $runtime = Join-Path $TestDrive 'rt_blank'
            $taskDir2 = Join-Path $runtime ('tasks\' + $taskId)
            New-Item -ItemType Directory -Path $taskDir2 -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $taskDir2 'contract.json') -Value '{"state":"routed"}' -Encoding utf8
            $content = ([char]0xFEFF).ToString() + $line1 + "`r`n   `r`n" + $line1 + "`r`n"
            [System.IO.File]::WriteAllText((Join-Path $runtime 'task_ledger.jsonl'), $content, [System.Text.UTF8Encoding]::new($false))

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('task:' + $taskId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 0
            $payload = $result.Output | ConvertFrom-Json
            $payload.latest_ledger_event.details.seq | Should -Be 1
        }

        It 'fails closed with exit code 2 on a malformed task id' {
            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', 'task:not-a-real-id', '-AsJson')
            $result.ExitCode | Should -Be 2
            $payload = $result.Output | ConvertFrom-Json
            $payload.ok | Should -Be $false
            $payload.schema_version | Should -Be '1.0'
            $payload.drift | Should -Be $true
        }

        It 'fails closed with exit code 2 when the contract file is absent' {
            $runtime = Join-Path $TestDrive 'rt_empty'
            New-Item -ItemType Directory -Path (Join-Path $runtime 'tasks') -Force | Out-Null

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', 'task:task-20260701-000000-aaaaaaaa', '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 2
            $payload = $result.Output | ConvertFrom-Json
            $payload.ok | Should -Be $false
        }
    }

    Context 'subject=graph:<id>' {
        It 'returns the graph contract and its latest ledger event' {
            $graphId = 'agent-os-graph-20260701-000000-aaaaaaaa'
            $runtime = Join-Path $TestDrive 'rt_graph'
            $graphDir = Join-Path $runtime $graphId
            New-Item -ItemType Directory -Path $graphDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $graphDir 'graph.json') -Value ('{"graph_id":"' + $graphId + '"}') -Encoding utf8
            $ledgerLines = @(
                '{"schema_version":"0.1","event_type":"graph_created","sequence":1}',
                '{"schema_version":"0.1","event_type":"node_dispatched","sequence":2}'
            )
            [System.IO.File]::WriteAllText((Join-Path $graphDir 'ledger.jsonl'), (($ledgerLines -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('graph:' + $graphId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 0
            $payload = $result.Output | ConvertFrom-Json
            $payload.ok | Should -Be $true
            $payload.schema_version | Should -Be '1.0'
            $payload.graph_id | Should -Be $graphId
            $payload.latest_ledger_event.event_type | Should -Be 'node_dispatched'
        }

        It 'tolerates a torn tail in the graph ledger' {
            $graphId = 'agent-os-graph-20260701-000000-bbbbbbbb'
            $runtime = Join-Path $TestDrive 'rt_graph_torn'
            $graphDir = Join-Path $runtime $graphId
            New-Item -ItemType Directory -Path $graphDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $graphDir 'graph.json') -Value ('{"graph_id":"' + $graphId + '"}') -Encoding utf8
            $ledgerLines = @(
                '{"schema_version":"0.1","event_type":"graph_created","sequence":1}',
                '{"schema_version":"0.1","event_type":"node_dispatched","sequence":2}'
            )
            $body = ($ledgerLines -join "`r`n") + "`r`n" + '{"schema_version":"0.1","event_type":"trunca'
            [System.IO.File]::WriteAllText((Join-Path $graphDir 'ledger.jsonl'), $body, [System.Text.UTF8Encoding]::new($false))

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('graph:' + $graphId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 0
            $payload = $result.Output | ConvertFrom-Json
            $payload.latest_ledger_event.event_type | Should -Be 'node_dispatched'
        }

        It 'fails closed when graph.json declares a different graph_id than the directory name' {
            $graphId = 'agent-os-graph-20260701-000000-aaaaaaaa'
            $runtime = Join-Path $TestDrive 'rt_graph_mismatch'
            $graphDir = Join-Path $runtime $graphId
            New-Item -ItemType Directory -Path $graphDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $graphDir 'graph.json') -Value '{"graph_id":"agent-os-graph-20260702-999999-bbbbbbbb"}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $graphDir 'ledger.jsonl') -Value '' -Encoding utf8

            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', ('graph:' + $graphId), '-RuntimeRoot', $runtime, '-AsJson')
            $result.ExitCode | Should -Be 2
            $payload = $result.Output | ConvertFrom-Json
            $payload.ok | Should -Be $false
        }
    }

    Context 'subject=health' {
        # 本 Context 全部用例使用 fixture 注册表（2026-08-06 fixture 化整改），
        # 不依赖真实 00-系统\项目注册表.md，保证可复现且不触碰治理源文件。
        It 'reports control plane, registry, ledger stats and entry gaps for active projects only' {
            $recentTs = ([DateTimeOffset]::Now.AddDays(-1)).ToString('o')
            $fixture = New-HealthFixture
            $runtime = New-TestRuntimeWithTask -TaskId 'task-20260701-000000-aaaaaaaa' -LedgerLines @(
                (New-LedgerLine -TaskId 'task-20260701-000000-aaaaaaaa' -Event 'contract_created' -Timestamp $recentTs -Seq 1)
            )
            $originalRegistrySource = $script:RegistrySourcePath
            $script:RegistrySourcePath = $fixture.RegistrySource

            try {
                $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', 'health', '-RuntimeRoot', $runtime, '-AsJson')
                $result.ExitCode | Should -Be 0
                $payload = $result.Output | ConvertFrom-Json
                $payload.ok | Should -Be $true
                $payload.schema_version | Should -Be '1.0'
                $payload.subject | Should -Be 'health'
                $payload.registry.projects_active | Should -Be 2
                $payload.ledger.present | Should -Be $true
                $payload.ledger.lines | Should -Be 1
                $payload.ledger.parse_fail_lines | Should -Be 0
                $payload.ledger.torn_tail | Should -Be $false
                $payload.ledger.stale | Should -Be $false
                @($payload.entry_gaps).Count | Should -Be 1
                $payload.entry_gaps[0].project_name | Should -Be '缺口样例'
                ($payload.entry_gaps[0].missing -contains 'root_path') | Should -Be $true
            }
            finally {
                $script:RegistrySourcePath = $originalRegistrySource
            }
        }

        It 'marks the ledger stale when the last event is older than 14 days' {
            $oldTs = ([DateTimeOffset]::Now.AddDays(-15)).ToString('o')
            $fixture = New-HealthFixture
            $runtime = New-TestRuntimeWithTask -TaskId 'task-20260701-000000-aaaaaaaa' -LedgerLines @(
                (New-LedgerLine -TaskId 'task-20260701-000000-aaaaaaaa' -Event 'contract_created' -Timestamp $oldTs -Seq 1)
            )
            $originalRegistrySource = $script:RegistrySourcePath
            $script:RegistrySourcePath = $fixture.RegistrySource

            try {
                $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', 'health', '-RuntimeRoot', $runtime, '-AsJson')
                $result.ExitCode | Should -Be 0
                $payload = $result.Output | ConvertFrom-Json
                $payload.ledger.stale | Should -Be $true
                $payload.ledger.stale_threshold_seconds | Should -Be (14 * 86400)
                $payload.ledger.last_event_age_seconds | Should -BeGreaterThan (14 * 86400)
            }
            finally {
                $script:RegistrySourcePath = $originalRegistrySource
            }
        }

        It 'treats a missing ledger as present=false and stale=true without failing' {
            $fixture = New-HealthFixture
            $runtime = Join-Path $TestDrive 'rt_health_noledger'
            New-Item -ItemType Directory -Path $runtime -Force | Out-Null
            $originalRegistrySource = $script:RegistrySourcePath
            $script:RegistrySourcePath = $fixture.RegistrySource

            try {
                $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', 'health', '-RuntimeRoot', $runtime, '-AsJson')
                $result.ExitCode | Should -Be 0
                $payload = $result.Output | ConvertFrom-Json
                $payload.ok | Should -Be $true
                $payload.ledger.present | Should -Be $false
                $payload.ledger.stale | Should -Be $true
            }
            finally {
                $script:RegistrySourcePath = $originalRegistrySource
            }
        }

        It 'counts a torn tail but fails closed on interior corrupt lines' {
            $recentTs = ([DateTimeOffset]::Now.AddDays(-1)).ToString('o')
            $fixture = New-HealthFixture
            $runtime = New-TestRuntimeWithTask -TaskId 'task-20260701-000000-aaaaaaaa' -LedgerLines @(
                (New-LedgerLine -TaskId 'task-20260701-000000-aaaaaaaa' -Event 'contract_created' -Timestamp $recentTs -Seq 1),
                'interior-corrupt-line',
                (New-LedgerLine -TaskId 'task-20260701-000000-aaaaaaaa' -Event 'worker_dispatched' -Timestamp $recentTs -Seq 2)
            )
            $originalRegistrySource = $script:RegistrySourcePath
            $script:RegistrySourcePath = $fixture.RegistrySource

            try {
                $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', 'health', '-RuntimeRoot', $runtime, '-AsJson')
                $result.ExitCode | Should -Be 2
                $payload = $result.Output | ConvertFrom-Json
                $payload.ok | Should -Be $false
            }
            finally {
                $script:RegistrySourcePath = $originalRegistrySource
            }
        }

        It 'reports torn_tail=true while staying ok for a truncated final line' {
            $recentTs = ([DateTimeOffset]::Now.AddDays(-1)).ToString('o')
            $fixture = New-HealthFixture
            $runtime = New-TestRuntimeWithTask -TaskId 'task-20260701-000000-aaaaaaaa' -LedgerLines @(
                (New-LedgerLine -TaskId 'task-20260701-000000-aaaaaaaa' -Event 'contract_created' -Timestamp $recentTs -Seq 1)
            )
            $ledgerPath = Join-Path $runtime 'task_ledger.jsonl'
            $bytes = [System.IO.File]::ReadAllBytes($ledgerPath)
            $torn = [System.Text.Encoding]::UTF8.GetBytes('{"timestamp":"2026-07-17T03:00:00+08:00","task_id":"task-2026070')
            $all = New-Object byte[] ($bytes.Length + $torn.Length)
            [Array]::Copy($bytes, 0, $all, 0, $bytes.Length)
            [Array]::Copy($torn, 0, $all, $bytes.Length, $torn.Length)
            [System.IO.File]::WriteAllBytes($ledgerPath, $all)
            $originalRegistrySource = $script:RegistrySourcePath
            $script:RegistrySourcePath = $fixture.RegistrySource

            try {
                $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', 'health', '-RuntimeRoot', $runtime, '-AsJson')
                $result.ExitCode | Should -Be 0
                $payload = $result.Output | ConvertFrom-Json
                $payload.ok | Should -Be $true
                $payload.ledger.torn_tail | Should -Be $true
                $payload.ledger.parse_fail_lines | Should -Be 1
                $payload.ledger.lines | Should -Be 1
            }
            finally {
                $script:RegistrySourcePath = $originalRegistrySource
            }
        }
    }

    Context 'unknown subject' {
        It 'fails closed with exit code 2 and lists supported subjects' {
            $result = Invoke-GraphEntryProcess -ArgumentList @('-Subject', 'nonsense', '-AsJson')
            $result.ExitCode | Should -Be 2
            $payload = $result.Output | ConvertFrom-Json
            $payload.ok | Should -Be $false
            $payload.schema_version | Should -Be '1.0'
            $payload.reason | Should -Match 'projects'
            $payload.reason | Should -Match 'health'
        }
    }
}
