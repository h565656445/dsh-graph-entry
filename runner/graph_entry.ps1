[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Subject,

    [string]$RuntimeRoot,

    [string]$RegistrySourcePath,

    [string]$CapabilitiesPath,

    [switch]$AsJson
)

# GraphEntry：<projects-root> 控制平面的只读发现入口。
# 只负责发现和核验：不派发任务、不批准副作用、不写完成状态、不触碰权威注册表镜像。
# Subject 取值：projects | task:<task_id> | graph:<graph_id> | health

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$vaultRoot = Split-Path -Parent (Split-Path -Parent $projectRoot)

if (-not $RuntimeRoot) {
    $RuntimeRoot = Join-Path $projectRoot 'runtime'
}
if (-not $RegistrySourcePath) {
    $RegistrySourcePath = Join-Path $vaultRoot '00-系统\项目注册表.md'
}
if (-not $CapabilitiesPath) {
    $CapabilitiesPath = Join-Path $projectRoot 'config\project_capabilities.json'
}

function Write-GraphEntryFailure {
    param(
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][int]$Code
    )
    $payload = [pscustomobject]@{
        ok = $false
        schema_version = '1.0'
        subject = $Subject
        drift = $true
        reason = $Reason
    }
    if ($AsJson) {
        $payload | ConvertTo-Json -Depth 20
    }
    else {
        Write-Host ("[GraphEntry drift] $Reason") -ForegroundColor Red
    }
    exit $Code
}

function Resolve-GraphEntryEntryPaths {
    param([Parameter(Mandatory)][string]$RootPath)

    $entryPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @('AGENTS.md', 'README.md')) {
        $path = Join-Path $RootPath $candidate
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $entryPaths.Add($path)
        }
    }
    return @($entryPaths)
}

function Get-GraphEntryLatestLedgerEvent {
    param(
        [Parameter(Mandatory)][string]$LedgerPath,
        [string]$TaskId
    )

    if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
        return $null
    }

    # 显式 UTF-8 读取（容忍 BOM）；账本只追加，逆序扫描并在首个匹配处停止。
    $content = [System.IO.File]::ReadAllText($LedgerPath, [System.Text.Encoding]::UTF8)
    $lines = $content -split "`r?`n"

    # 末尾不完整行（写入中断）容忍：跳过文件最后一条无法解析的非空行；
    # 其前的坏行仍按损坏处理，失败关闭。
    $tornTailChecked = $false
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $null
        try {
            $event = $line | ConvertFrom-Json
        }
        catch {
            if (-not $tornTailChecked) {
                $tornTailChecked = $true
                continue
            }
            Write-GraphEntryFailure -Reason "账本存在无法解析的行: $LedgerPath" -Code 2
        }
        if ($TaskId -and [string]$event.task_id -ne $TaskId) { continue }
        return $event
    }

    return $null
}

function Get-GraphEntryLedgerHealth {
    param([Parameter(Mandatory)][string]$LedgerPath)

    # stale 定义（2026-08-06 批次 2 批准）：阈值 14 天；全部任务状态参与；
    # 时间来源 = 账本最后一条事件 timestamp 与当前系统时间之差；纯信息，不影响退出码。
    $staleThresholdSeconds = [int64](14 * 86400)
    $info = [ordered]@{
        path = $LedgerPath
        present = $false
        lines = 0
        parse_fail_lines = 0
        torn_tail = $false
        last_event_ts = $null
        last_event_age_seconds = $null
        stale = $true
        stale_threshold_seconds = $staleThresholdSeconds
    }
    if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
        return [pscustomobject]$info
    }

    $content = [System.IO.File]::ReadAllText($LedgerPath, [System.Text.Encoding]::UTF8)
    $segments = @($content -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $info['present'] = $true
    if ($segments.Count -eq 0) {
        return [pscustomobject]$info
    }

    $lastEvent = $null
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $event = $null
        try {
            $event = $segments[$i] | ConvertFrom-Json
        }
        catch {
            $info['parse_fail_lines'] = [int]$info['parse_fail_lines'] + 1
            if ($i -eq $segments.Count - 1) {
                $info['torn_tail'] = $true
            }
            else {
                Write-GraphEntryFailure -Reason "账本存在无法解析的行: $LedgerPath" -Code 2
            }
            continue
        }
        $info['lines'] = [int]$info['lines'] + 1
        $lastEvent = $event
    }

    if ($lastEvent) {
        $info['last_event_ts'] = [string]$lastEvent.timestamp
        $parsedTs = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$lastEvent.timestamp, [ref]$parsedTs)) {
            $age = [int64]([DateTimeOffset]::Now - $parsedTs).TotalSeconds
            $info['last_event_age_seconds'] = $age
            $info['stale'] = $age -gt $staleThresholdSeconds
        }
    }

    return [pscustomobject]$info
}



# ---------- 前置核验：控制平面权威文件必须在位 ----------
foreach ($required in @($RegistrySourcePath, $CapabilitiesPath, (Join-Path $projectRoot 'src\HermesHarness.psm1'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-GraphEntryFailure -Reason "Harness 控制平面权威文件缺失: $required" -Code 2
    }
}

# ---------- Subject 路由 ----------
if ($Subject -eq 'projects') {
    Import-Module (Join-Path $projectRoot 'src\HermesHarness.psm1') -Force

    # 临时投影：不覆盖 generated\project_registry.json，保持治理 SHA 链不变。
    $projectionPath = Join-Path ([System.IO.Path]::GetTempPath()) ('graph_entry_projection_' + [System.IO.Path]::GetRandomFileName() + '.json')
    try {
        $registry = Update-HarnessProjectRegistry `
            -SourcePath $RegistrySourcePath `
            -CapabilitiesPath $CapabilitiesPath `
            -OutputPath $projectionPath

        $projects = foreach ($project in @($registry.projects)) {
            [pscustomobject]@{
                id = $project.id
                name = $project.name
                status = $project.status
                root_path = $project.root_path
                memory_path = $project.memory_path
                objective = $project.objective
                routable = [bool]$project.routable
                domains = @($project.domains)
                actions = @($project.actions)
                entry_paths = (Resolve-GraphEntryEntryPaths -RootPath ([string]$project.root_path))
            }
        }

        $payload = [pscustomobject]@{
            ok = $true
            schema_version = '1.0'
            subject = 'projects'
            drift = $false
            control_plane_root = $projectRoot
            registry_source_path = [string]$registry.source_path
            registry_source_sha256 = [string]$registry.source_sha256
            generated_at = [string]$registry.generated_at
            projects = @($projects)
        }

        if ($AsJson) {
            $payload | ConvertTo-Json -Depth 20
        }
        else {
            Write-Host ('Registry source: {0}' -f $registry.source_path)
            $projects | Select-Object name, status, routable, root_path, objective | Format-Table -AutoSize
        }
        exit 0
    }
    finally {
        if (Test-Path -LiteralPath $projectionPath) {
            Remove-Item -LiteralPath $projectionPath -Force
        }
    }
}
elseif ($Subject -like 'task:*') {
    $taskId = $Subject.Substring('task:'.Length)
    if ($taskId -notmatch '^task-\d{8}-\d{6}-[a-f0-9]{8}$') {
        Write-GraphEntryFailure -Reason "任务 ID 格式不符合 task-YYYYMMDD-HHMMSS-<8hex>: $taskId" -Code 2
    }

    $taskDirectory = Join-Path (Join-Path $RuntimeRoot 'tasks') $taskId
    $contractPath = Join-Path $taskDirectory 'contract.json'
    if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
        Write-GraphEntryFailure -Reason "TaskContract 不存在: $contractPath" -Code 2
    }

    $contract = Get-Content -Raw -LiteralPath $contractPath | ConvertFrom-Json
    $ledgerPath = Join-Path $RuntimeRoot 'task_ledger.jsonl'
    $latestEvent = Get-GraphEntryLatestLedgerEvent -LedgerPath $ledgerPath -TaskId $taskId

    $recoveryEvidence = @('input.txt', 'worker_package.json', 'execution_receipt.json', 'result.txt' |
        ForEach-Object { Join-Path $taskDirectory $_ } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })

    $payload = [pscustomobject]@{
        ok = $true
        schema_version = '1.0'
        subject = $Subject
        drift = $false
        task_id = $taskId
        state = [string]$contract.state
        task_directory = $taskDirectory
        contract_path = $contractPath
        ledger_path = $ledgerPath
        latest_ledger_event = $latestEvent
        recovery_evidence = $recoveryEvidence
    }

    if ($AsJson) {
        $payload | ConvertTo-Json -Depth 20
    }
    else {
        Write-Host ('task_id  : {0}' -f $taskId)
        Write-Host ('state    : {0}' -f $contract.state)
        Write-Host ('contract : {0}' -f $contractPath)
        Write-Host ('ledger   : {0}' -f $ledgerPath)
        if ($latestEvent) {
            Write-Host ('latest   : {0} / {1}' -f $latestEvent.state, $latestEvent.event)
        }
    }
    exit 0
}
elseif ($Subject -like 'graph:*') {
    $graphId = $Subject.Substring('graph:'.Length)
    if ($graphId -notmatch '^agent-os-graph-\d{8}-\d{6}-[a-f0-9]{8}$') {
        Write-GraphEntryFailure -Reason "Graph ID 格式不符合 agent-os-graph-YYYYMMDD-HHMMSS-<8hex>: $graphId" -Code 2
    }

    $graphPath = Join-Path $RuntimeRoot $graphId
    if (-not (Test-Path -LiteralPath $graphPath -PathType Container)) {
        Write-GraphEntryFailure -Reason "Agent OS graph 运行态不存在: $graphPath" -Code 2
    }
    $item = Get-Item -LiteralPath $graphPath
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Write-GraphEntryFailure -Reason "Agent OS graph 路径是重解析点，拒绝跟随: $graphPath" -Code 2
    }

    $contractPath = Join-Path $graphPath 'graph.json'
    $ledgerPath = Join-Path $graphPath 'ledger.jsonl'
    foreach ($required in @($contractPath, $ledgerPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            Write-GraphEntryFailure -Reason "Agent OS graph 缺少合同或账本: $required" -Code 2
        }
    }

    $contract = Get-Content -Raw -LiteralPath $contractPath | ConvertFrom-Json
    if ([string]$contract.graph_id -ne $graphId) {
        Write-GraphEntryFailure -Reason "graph.json 内声明的 graph_id 与目录名不一致" -Code 2
    }

    $latestEvent = Get-GraphEntryLatestLedgerEvent -LedgerPath $ledgerPath

    $payload = [pscustomobject]@{
        ok = $true
        schema_version = '1.0'
        subject = $Subject
        drift = $false
        graph_id = $graphId
        graph_path = $graphPath
        contract_path = $contractPath
        ledger_path = $ledgerPath
        latest_ledger_event = $latestEvent
    }

    if ($AsJson) {
        $payload | ConvertTo-Json -Depth 20
    }
    else {
        Write-Host ('graph_id : {0}' -f $graphId)
        Write-Host ('contract : {0}' -f $contractPath)
        Write-Host ('ledger   : {0}' -f $ledgerPath)
        if ($latestEvent) {
            Write-Host ('latest   : {0}' -f $latestEvent.event_type)
        }
    }
    exit 0
}
elseif ($Subject -eq 'health') {
    Import-Module (Join-Path $projectRoot 'src\HermesHarness.psm1') -Force

    # 临时投影：不覆盖 generated\project_registry.json，保持治理 SHA 链不变。
    $projectionPath = Join-Path ([System.IO.Path]::GetTempPath()) ('graph_entry_health_' + [System.IO.Path]::GetRandomFileName() + '.json')
    try {
        $registry = Update-HarnessProjectRegistry `
            -SourcePath $RegistrySourcePath `
            -CapabilitiesPath $CapabilitiesPath `
            -OutputPath $projectionPath

        $activeProjects = @(@($registry.projects) | Where-Object { [string]$_.status -eq 'active' })
        $entryGaps = [System.Collections.Generic.List[object]]::new()
        foreach ($project in $activeProjects) {
            $missing = [System.Collections.Generic.List[string]]::new()
            $rootPath = [string]$project.root_path
            if (-not $rootPath -or -not (Test-Path -LiteralPath $rootPath -PathType Container)) {
                $missing.Add('root_path')
            }
            else {
                $hasEntry = $false
                foreach ($candidate in @('AGENTS.md', 'README.md')) {
                    if (Test-Path -LiteralPath (Join-Path $rootPath $candidate) -PathType Leaf) { $hasEntry = $true }
                }
                if (-not $hasEntry) { $missing.Add('entry_file') }
            }
            if ($missing.Count -gt 0) {
                $entryGaps.Add([pscustomobject]@{
                    project_id = [string]$project.id
                    project_name = [string]$project.name
                    root_path = $rootPath
                    missing = @($missing)
                })
            }
        }

        $ledgerInfo = Get-GraphEntryLedgerHealth -LedgerPath (Join-Path $RuntimeRoot 'task_ledger.jsonl')

        $payload = [pscustomobject]@{
            ok = $true
            schema_version = '1.0'
            subject = 'health'
            drift = $false
            control_plane_root = $projectRoot
            registry = [pscustomobject]@{
                source_path = [string]$registry.source_path
                source_sha256 = [string]$registry.source_sha256
                projects_total = @($registry.projects).Count
                projects_active = $activeProjects.Count
            }
            ledger = $ledgerInfo
            entry_gaps = @($entryGaps)
        }

        if ($AsJson) {
            $payload | ConvertTo-Json -Depth 20
        }
        else {
            Write-Host ('registry   : {0} active / {1} total' -f $activeProjects.Count, @($registry.projects).Count)
            Write-Host ('ledger     : present={0} lines={1} stale={2}' -f $ledgerInfo.present, $ledgerInfo.lines, $ledgerInfo.stale)
            Write-Host ('entry_gaps : {0}' -f $entryGaps.Count)
        }
        exit 0
    }
    finally {
        if (Test-Path -LiteralPath $projectionPath) {
            Remove-Item -LiteralPath $projectionPath -Force
        }
    }
}
else {
    Write-GraphEntryFailure -Reason "无法识别的 Subject：$Subject（支持 projects | task:<id> | graph:<id> | health）" -Code 2
}
