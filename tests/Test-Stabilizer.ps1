$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$parseErrors = $null
$tokens = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $projectRoot 'run_stabilizer.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

foreach ($functionName in @('Get-WarpStatus', 'Add-Sample', 'Get-Stats')) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if ($null -eq $definition) { throw "Missing function: $functionName" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Test-WarpCli {
    $global:LASTEXITCODE = $script:MockExit
    return $script:MockStatus
}

$script:WarpAvailable = $true
$script:WarpCliPath = 'Test-WarpCli'
foreach ($case in @(
    @('Status update: Disconnected', 0, 'disconnected'),
    @('Status update: Connected', 0, 'connected'),
    @('Status update: Connecting', 0, 'unknown'),
    @('Status update: Connected', 1, 'error')
)) {
    $script:MockStatus = $case[0]
    $script:MockExit = $case[1]
    $actual = Get-WarpStatus
    if ($actual -ne $case[2]) { throw "WARP status: expected $($case[2]), got $actual" }
}
$script:WarpAvailable = $false
if ((Get-WarpStatus) -ne 'unavailable') { throw 'Missing WARP was not reported' }

$history = Add-Sample -History $null -Latency 10 -HistorySize 3
$history = Add-Sample -History $history -Latency 20 -HistorySize 3
$history = Add-Sample -History $history -Latency $null -HistorySize 3
$stats = Get-Stats -History $history
if ($stats.avg_ms -ne 15 -or $stats.jitter_ms -ne 10 -or
    [Math]::Abs($stats.loss_percent - (100.0 / 3)) -gt 0.001 -or $null -ne $stats.latest_ms) {
    throw 'History statistics or timeout tracking regressed'
}
$history = Add-Sample -History $history -Latency 30 -HistorySize 3
if ($history.Count -ne 3 -or $history[0] -ne 20) { throw 'History window is not bounded' }

$switchCalls = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Switch-ToProfile'
}, $true))
if ($switchCalls.Count) { throw 'Invalid automatic route comparison is still used to switch profiles' }

foreach ($functionName in @('Restore-WindowsNetworkDefaults', 'Start-SessionStabilization', 'Stop-SessionStabilization', 'Restore-PreviousSessionIfNeeded')) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if ($null -eq $definition) { throw "Missing function: $functionName" }
}

$config = [IO.File]::ReadAllText((Join-Path $projectRoot 'config.json')) | ConvertFrom-Json
foreach ($flag in @('enabled', 'apply_tcp_profile', 'flush_dns_on_spike', 'reset_adapter_on_spike',
    'run_profile_command_on_switch', 'allow_warp_auto_switch', 'allow_dns_route_switch')) {
    if ($config.actions.$flag) { throw "Default network-changing action is enabled: $flag" }
}
if (-not $config.stabilize.enabled -or -not $config.stabilize.revert_legacy_tweaks) {
    throw 'Session stabilization or legacy tweak revert is disabled by default'
}

$launcher = [IO.File]::ReadAllText((Join-Path $projectRoot 'run.bat'))
$commands = [regex]::Matches($launcher, '(?m)^\s*powershell\.exe -NoProfile -Command "([^"]+)"')
if ($commands.Count -ne 2) { throw 'Expected administrator check and elevation command' }
foreach ($command in $commands) {
    [void][Management.Automation.Language.Parser]::ParseInput(
        $command.Groups[1].Value, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
if ($launcher -match 'net session' -or $launcher -notmatch 'WindowsBuiltInRole.*Administrator' -or
    $launcher -notmatch 'if /i "%~1"=="--elevated"') {
    throw 'Administrator token check or elevation-loop guard regressed'
}

Write-Output 'PASS: syntax, WARP states, history statistics, disabled auto-switching, safe defaults, and launcher guards.'