param(
    [string]$Config = "config.json",
    [string]$LogPath = ".\logs\stabilizer.log",
    [string]$Game = ""
)

$ErrorActionPreference = "Stop"

# ── Helpers ──────────────────────────────────────────────────────────────────

function Get-NowStamp {
    return (Get-Date).ToString("HH:mm:ss")
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )

    $line = "[$(Get-NowStamp)] [$Level] $Message"
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Invoke-PingMs {
    param(
        [Parameter(Mandatory = $true)][string]$TargetHost,
        [int]$TimeoutMs = 900
    )

    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($TargetHost, $TimeoutMs)
        $ping.Dispose()

        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            return [double]$reply.RoundtripTime
        }
    } catch {}

    return $null
}

function Add-Sample {
    param(
        [AllowNull()]$History,
        [AllowNull()]$Latency,
        [int]$HistorySize
    )

    if ($null -eq $History) {
        $History = New-Object System.Collections.ArrayList
    }

    if ($History -isnot [System.Collections.ArrayList]) {
        $normalized = New-Object System.Collections.ArrayList
        foreach ($item in @($History)) {
            [void]$normalized.Add($item)
        }
        $History = $normalized
    }

    [void]$History.Add($Latency)
    while ($History.Count -gt $HistorySize) {
        $History.RemoveAt(0)
    }

    return ,([System.Collections.ArrayList]$History)
}

function Get-Stats {
    param(
        [AllowNull()]$History
    )

    if ($null -eq $History) {
        return [pscustomobject]@{
            avg_ms = 9999.0
            jitter_ms = 9999.0
            loss_percent = 100.0
            score = 9999.0
            latest_ms = $null
        }
    }

    if ($History -isnot [System.Collections.ArrayList]) {
        $normalized = New-Object System.Collections.ArrayList
        foreach ($item in @($History)) {
            [void]$normalized.Add($item)
        }
        $History = $normalized
    }

    if ($History.Count -eq 0) {
        return [pscustomobject]@{
            avg_ms = 9999.0
            jitter_ms = 9999.0
            loss_percent = 100.0
            score = 9999.0
            latest_ms = $null
        }
    }

    $latencies = @($History | Where-Object { $_ -ne $null } | ForEach-Object { [double]$_ })
    $misses = @($History | Where-Object { $_ -eq $null }).Count

    if ($latencies.Count -eq 0) {
        return [pscustomobject]@{
            avg_ms = 9999.0
            jitter_ms = 9999.0
            loss_percent = 100.0
            score = 9999.0
            latest_ms = $null
        }
    }

    $avg = ($latencies | Measure-Object -Average).Average

    $jitter = 0.0
    if ($latencies.Count -gt 1) {
        $diffs = New-Object System.Collections.Generic.List[double]
        for ($i = 1; $i -lt $latencies.Count; $i++) {
            $prev = [double]$latencies[$i - 1]
            $curr = [double]$latencies[$i]
            [void]$diffs.Add([Math]::Abs($curr - $prev))
        }
        $jitter = ($diffs | Measure-Object -Average).Average
    }

    $loss = ([double]$misses / [double]$History.Count) * 100.0
    $score = $avg + ($jitter * 1.7) + ($loss * 6.0)

    return [pscustomobject]@{
        avg_ms = [double]$avg
        jitter_ms = [double]$jitter
        loss_percent = [double]$loss
        score = [double]$score
        latest_ms = $History[$History.Count - 1]
    }
}

function Test-IsSpike {
    param(
        [double]$Current,
        [double]$Baseline,
        [double]$AbsoluteLimit,
        [double]$MultiplierLimit
    )

    return (($Current - $Baseline) -ge $AbsoluteLimit) -and ($Current -ge ($Baseline * $MultiplierLimit))
}

function Invoke-ProfileCommand {
    param(
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return
    }

    try {
        $output = cmd /c $Command 2>&1 | Out-String
        return $output.Trim()
    } catch {
        return "error: $($_.Exception.Message)"
    }
}

# ── WARP Helpers ─────────────────────────────────────────────────────────────

$script:WarpCliPath = $null
$script:WarpAvailable = $false
$script:CurrentProfile = "direct"

function Find-WarpCli {
    $candidates = @(
        "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe",
        "C:\Program Files (x86)\Cloudflare\Cloudflare WARP\warp-cli.exe"
    )
    $inPath = Get-Command warp-cli -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Get-WarpStatus {
    if (-not $script:WarpAvailable) { return "unavailable" }
    try {
        $output = & $script:WarpCliPath status 2>&1 | Out-String
        if ($output -match "Connected") { return "connected" }
        if ($output -match "Disconnected") { return "disconnected" }
        return "unknown"
    } catch {
        return "error"
    }
}

# ── DNS Route Helpers (admin, no WARP required) ──────────────────────────────

$script:DnsRoutes = @{}
$script:IsAdmin = $false
$script:OriginalDnsSaved = $false
$script:OriginalDnsServers = @()
$script:ActiveIfIndex = $null

function Get-ActiveAdapterIndex {
    try {
        $cfg = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
            Select-Object -First 1
        if ($cfg) { return [int]$cfg.InterfaceIndex }
    } catch {}
    return $null
}

function Save-OriginalDns {
    if ($script:OriginalDnsSaved) { return }
    if ($null -eq $script:ActiveIfIndex) { $script:ActiveIfIndex = Get-ActiveAdapterIndex }
    if ($null -eq $script:ActiveIfIndex) { return }
    try {
        $current = Get-DnsClientServerAddress -InterfaceIndex $script:ActiveIfIndex -AddressFamily IPv4 -ErrorAction Stop
        $script:OriginalDnsServers = @($current.ServerAddresses)
        $script:OriginalDnsSaved = $true
    } catch {}
}

function Set-DnsRoute {
    param([string[]]$Servers)
    if ($null -eq $script:ActiveIfIndex) { $script:ActiveIfIndex = Get-ActiveAdapterIndex }
    if ($null -eq $script:ActiveIfIndex) {
        Write-Log -Level "WARN" -Message "  Could not find active network adapter for DNS route"
        return $false
    }
    Save-OriginalDns
    try {
        if ($null -eq $Servers -or $Servers.Count -eq 0) {
            Set-DnsClientServerAddress -InterfaceIndex $script:ActiveIfIndex -ResetServerAddresses -ErrorAction Stop
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $script:ActiveIfIndex -ServerAddresses $Servers -ErrorAction Stop
        }
        ipconfig /flushdns 2>&1 | Out-Null
        return $true
    } catch {
        Write-Log -Level "WARN" -Message "  DNS route change failed: $($_.Exception.Message)"
        return $false
    }
}

function Restore-OriginalDns {
    if (-not $script:OriginalDnsSaved -or $null -eq $script:ActiveIfIndex) { return }
    try {
        if ($script:OriginalDnsServers.Count -eq 0) {
            Set-DnsClientServerAddress -InterfaceIndex $script:ActiveIfIndex -ResetServerAddresses -ErrorAction SilentlyContinue
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $script:ActiveIfIndex -ServerAddresses $script:OriginalDnsServers -ErrorAction SilentlyContinue
        }
        ipconfig /flushdns 2>&1 | Out-Null
        Write-Log -Message "DNS restored to original settings."
    } catch {}
}

function Select-Game {
    param(
        [array]$Games,
        [string]$Requested
    )

    # Non-interactive selection by name (case-insensitive substring match).
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        if ($Requested -match '^(all|any)$') { return "ALL" }
        $match = $Games | Where-Object { ([string]$_.name).ToLower().Contains($Requested.ToLower()) } | Select-Object -First 1
        if ($match) { return [string]$match.name }
        Write-Log -Level "WARN" -Message "Game '$Requested' not found in config; showing menu."
    }

    Write-Host ""
    Write-Host "Which game are you going to play?" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Games.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), [string]$Games[$i].name)
    }
    Write-Host ("  [{0}] All games (monitor everything)" -f ($Games.Count + 1))
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter number"
        $n = 0
        if ([int]::TryParse($choice, [ref]$n)) {
            if ($n -ge 1 -and $n -le $Games.Count) { return [string]$Games[$n - 1].name }
            if ($n -eq ($Games.Count + 1)) { return "ALL" }
        }
        Write-Host "Invalid choice, try again." -ForegroundColor Yellow
    }
}

function Switch-ToProfile {
    param(
        [string]$ProfileName,
        [hashtable]$ProfileCommands
    )

    if ($ProfileName -eq $script:CurrentProfile) { return }

    # Leaving WARP: disconnect first so DNS/direct routes take effect.
    if ($script:CurrentProfile -eq "warp" -and $script:WarpAvailable) {
        try {
            & $script:WarpCliPath disconnect 2>&1 | Out-Null
            Write-Log -Message "WARP -> disconnected"
        } catch {
            Write-Log -Level "WARN" -Message "WARP disconnect failed: $($_.Exception.Message)"
        }
    }

    if ($ProfileName -eq "warp") {
        if ($script:WarpAvailable) {
            try {
                & $script:WarpCliPath connect 2>&1 | Out-Null
                Write-Log -Message "WARP -> connected"
            } catch {
                Write-Log -Level "WARN" -Message "WARP connect failed: $($_.Exception.Message)"
            }
        }
    } elseif ($script:DnsRoutes.ContainsKey($ProfileName)) {
        if ($script:IsAdmin) {
            $ok = Set-DnsRoute -Servers @($script:DnsRoutes[$ProfileName])
            if ($ok) {
                Write-Log -Message ("DNS route -> {0} [{1}]" -f $ProfileName, ($script:DnsRoutes[$ProfileName] -join ", "))
            }
        } else {
            Write-Log -Level "WARN" -Message "DNS route '$ProfileName' needs Administrator; skipped."
        }
    } elseif ($ProfileCommands.ContainsKey($ProfileName)) {
        Invoke-ProfileCommand -Command $ProfileCommands[$ProfileName]
    }

    $script:CurrentProfile = $ProfileName
}

function Get-OrCreateHistory {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Store,
        [Parameter(Mandatory = $true)][string]$TargetName
    )

    if ([string]::IsNullOrWhiteSpace($TargetName)) {
        throw "target name is empty"
    }

    if (-not $Store.ContainsKey($TargetName) -or $null -eq $Store[$TargetName]) {
        $Store[$TargetName] = New-Object System.Collections.ArrayList
    }

    return ,([System.Collections.ArrayList]$Store[$TargetName])
}

if (-not (Test-Path -LiteralPath $Config)) {
    throw "Config file not found: $Config"
}

$logDirectory = Split-Path -Parent $LogPath
if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

# ── Admin Check ──────────────────────────────────────────────────────────────

function Test-IsAdmin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-IsAdmin

# ── Network Optimization ─────────────────────────────────────────────────────

function Set-NetworkOptimizations {
    param([bool]$IsAdmin)

    Write-Log -Message "Applying network optimizations for gaming..."

    # Flush DNS cache
    try {
        ipconfig /flushdns 2>&1 | Out-Null
        Write-Log -Message "  DNS cache flushed"
    } catch {
        Write-Log -Level "WARN" -Message "  Failed to flush DNS: $($_.Exception.Message)"
    }

    if (-not $IsAdmin) {
        Write-Log -Level "WARN" -Message "  Not running as admin - TCP/registry optimizations skipped"
        Write-Log -Level "WARN" -Message "  Right-click run.bat -> 'Run as administrator' for full optimization"
        return
    }

    # TCP optimizations - reduce latency for gaming
    $tcpCommands = @(
        @{ cmd = "netsh int tcp set global autotuninglevel=normal";       desc = "TCP auto-tuning: normal" },
        @{ cmd = "netsh int tcp set global ecncapability=enabled";        desc = "ECN: enabled" },
        @{ cmd = "netsh int tcp set global rss=enabled";                  desc = "RSS: enabled" },
        @{ cmd = "netsh int tcp set global timestamps=disabled";          desc = "TCP timestamps: disabled (less overhead)" },
        @{ cmd = "netsh int tcp set global nonsackrttresiliency=disabled"; desc = "Non-SACK RTT resiliency: disabled" },
        @{ cmd = "netsh int tcp set global initialRto=2000";              desc = "Initial RTO: 2000ms" }
    )

    foreach ($entry in $tcpCommands) {
        try {
            cmd /c $entry.cmd 2>&1 | Out-Null
            Write-Log -Message "  $($entry.desc)"
        } catch {
            Write-Log -Level "WARN" -Message "  Failed: $($entry.desc)"
        }
    }

    # Disable Nagle's algorithm on all interfaces (reduces micro-delays)
    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
        $subkeys = Get-ChildItem $regPath -ErrorAction SilentlyContinue
        foreach ($subkey in $subkeys) {
            try {
                Set-ItemProperty -Path $subkey.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $subkey.PSPath -Name "TCPNoDelay" -Value 1 -Type DWord -ErrorAction SilentlyContinue
            } catch {}
        }
        Write-Log -Message "  Nagle's algorithm: disabled (TcpAckFrequency=1, TCPNoDelay=1)"
    } catch {
        Write-Log -Level "WARN" -Message "  Failed to disable Nagle: $($_.Exception.Message)"
    }

    # Disable network throttling for games
    try {
        $mmPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
        Set-ItemProperty -Path $mmPath -Name "NetworkThrottlingIndex" -Value 0xFFFFFFFF -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $mmPath -Name "SystemResponsiveness" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Write-Log -Message "  Network throttling: disabled"
        Write-Log -Message "  System responsiveness: foreground priority"
    } catch {
        Write-Log -Level "WARN" -Message "  Failed to set throttling registry: $($_.Exception.Message)"
    }

    Write-Log -Message "Network optimizations applied."
}

# ── Startup ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "   Game Connection Stabilizer (Multi-Game)" -ForegroundColor Cyan
Write-Host "   Valorant | League | World of Tanks | Minecraft | more" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

Write-Log -Message "Starting Game Stabilizer (multi-game)"
Write-Log -Message "Config: $Config"
Write-Log -Message "Log file: $LogPath"
Write-Log -Message "Admin privileges: $(if ($isAdmin) { 'YES' } else { 'NO' })"

$configRaw = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json

$script:IsAdmin = [bool]$isAdmin

# ── Parse games (monitors), routes (switchable), and DNS routes ───────────────
$games = @()
foreach ($g in @($configRaw.games)) {
    $gname = [string]$g.name
    if ([string]::IsNullOrWhiteSpace($gname)) { continue }
    $ghosts = @()
    foreach ($h in @($g.hosts)) {
        $hs = [string]$h
        if (-not [string]::IsNullOrWhiteSpace($hs)) { $ghosts += $hs.Trim() }
    }
    if ($ghosts.Count -eq 0) { continue }
    $games += [pscustomobject]@{ name = $gname.Trim(); hosts = $ghosts }
}

if ($games.Count -eq 0) {
    throw "Config must include at least one game in 'games'."
}

# DNS routes map (profile name -> server list)
foreach ($p in $configRaw.dns_routes.PSObject.Properties) {
    $servers = @()
    foreach ($s in @($p.Value)) {
        $ss = [string]$s
        if (-not [string]::IsNullOrWhiteSpace($ss)) { $servers += $ss.Trim() }
    }
    $script:DnsRoutes[$p.Name] = $servers
}

# Route candidates (what the tool actually switches between)
$routeTargets = @()
foreach ($r in @($configRaw.routes)) {
    $rname = [string]$r.name
    $rhost = [string]$r.host
    $rprofile = [string]$r.profile
    if ([string]::IsNullOrWhiteSpace($rname) -or [string]::IsNullOrWhiteSpace($rhost)) { continue }
    if ([string]::IsNullOrWhiteSpace($rprofile)) { $rprofile = "direct" }
    $routeTargets += [pscustomobject]@{
        name    = $rname.Trim()
        host    = $rhost.Trim()
        profile = $rprofile.Trim()
        role    = "route"
    }
}

$thresholds = $configRaw.thresholds
$actions = $configRaw.actions
$runtime = $configRaw.runtime
$profileCommands = @{}

foreach ($p in $configRaw.profile_commands.PSObject.Properties) {
    $profileCommands[$p.Name] = [string]$p.Value
}

# ── Choose the game to stabilize for ─────────────────────────────────────────
$selectedGame = Select-Game -Games $games -Requested $Game

$monitors = @()
if ($selectedGame -eq "ALL") {
    foreach ($g in $games) {
        foreach ($h in $g.hosts) {
            $monitors += [pscustomobject]@{ name = ("{0}: {1}" -f $g.name, $h); host = $h; profile = "direct"; role = "monitor" }
        }
    }
    Write-Log -Message "Selected game: ALL GAMES (monitoring everything)"
} else {
    $g = $games | Where-Object { [string]$_.name -eq $selectedGame } | Select-Object -First 1
    foreach ($h in $g.hosts) {
        $monitors += [pscustomobject]@{ name = ("{0}: {1}" -f $g.name, $h); host = $h; profile = "direct"; role = "monitor" }
    }
    Write-Log -Message "Selected game: $selectedGame"
}

# Combined ping set: game monitors (spike watch) + route candidates (switchable)
$targets = @()
$targets += $monitors
$targets += $routeTargets

# Detect Cloudflare WARP
$script:WarpCliPath = Find-WarpCli
if ($script:WarpCliPath) {
    $script:WarpAvailable = $true
    $warpStatus = Get-WarpStatus
    Write-Log -Message "Cloudflare WARP: FOUND ($($script:WarpCliPath))"
    Write-Log -Message "WARP status: $warpStatus"
    if ($warpStatus -eq "connected") {
        $script:CurrentProfile = "warp"
    }
    Write-Host "" -ForegroundColor Green
    Write-Host "  WARP is available! The stabilizer will auto-switch" -ForegroundColor Green
    Write-Host "  between direct and WARP based on which route is faster." -ForegroundColor Green
    Write-Host ""
} else {
    Write-Log -Level "WARN" -Message "Cloudflare WARP: NOT FOUND"
    Write-Log -Level "WARN" -Message "  Install WARP for automatic route optimization:"
    Write-Log -Level "WARN" -Message "  Installer at: $env:TEMP\Cloudflare_WARP_Release-x64.msi"
}

# Startup network changes are opt-in. The default monitor-only mode must not
# modify DNS, TCP, registry settings, or the active route.
    if ([bool]$actions.enabled -and [bool]$actions.apply_tcp_profile) {
    Set-NetworkOptimizations -IsAdmin $isAdmin
} else {
    Write-Log -Message "Monitor-only mode: startup network changes skipped."
}

$histories = @{}
foreach ($target in $targets) {
    $name = [string]$target.name
    [void](Get-OrCreateHistory -Store $histories -TargetName $name)
}

# The route currently applied (matches $script:CurrentProfile where possible).
$activeRouteName = ""
$rtInit = $routeTargets | Where-Object { [string]$_.profile -eq $script:CurrentProfile } | Select-Object -First 1
if ($rtInit) { $activeRouteName = [string]$rtInit.name } elseif ($routeTargets.Count -gt 0) { $activeRouteName = [string]$routeTargets[0].name }

$consecutiveSpikes = 0
$lastSwitchedAt = [datetime]::MinValue
$totalCycles = 0
$totalFlushes = 0
$totalSwitches = 0

Write-Host ""
Write-Log -Message "Stabilizing for: $selectedGame  (monitors: $($monitors.Count), routes: $($routeTargets.Count))"

# A real reroute is possible via WARP, or via DNS route switching when running as admin.
$dnsRouteReady = ($script:IsAdmin -and $script:DnsRoutes.Count -gt 0)
$script:CanReroute = [bool]$script:WarpAvailable -or $dnsRouteReady

if ($script:WarpAvailable -and $script:IsAdmin) {
    Write-Log -Message "MODE: ACTIVE - WARP + DNS route switching + system tweaks enabled."
} elseif ($script:WarpAvailable) {
    Write-Log -Level "WARN" -Message "MODE: PARTIAL - WARP route switching on; run as Administrator for DNS routes + TCP tweaks."
} elseif ($dnsRouteReady) {
    Write-Log -Message "MODE: ACTIVE (DNS) - no WARP, but admin DNS route switching is enabled."
    Write-Log -Message "  The tool A/B tests DNS providers (Cloudflare / Google / Quad9) and keeps the fastest."
    Write-Log -Message "  This is a modest but real lever; it does not tunnel game packets like WARP/ExitLag."
} else {
    Write-Log -Level "WARN" -Message "MODE: MONITOR-ONLY - no reroute available."
    Write-Log -Level "WARN" -Message "  Run as Administrator to enable DNS route switching, or install Cloudflare WARP."
}
Write-Host ""

# ── Main Loop ─────────────────────────────────────────────────────────────────

try {
    while ($true) {
        try {
            $totalCycles++

            # Ping all targets (game monitors + route candidates)
            foreach ($target in $targets) {
                $name = [string]$target.name
                $history = Get-OrCreateHistory -Store $histories -TargetName $name

                $latency = Invoke-PingMs -TargetHost ([string]$target.host)
                $history = Add-Sample -History $history -Latency $latency -HistorySize ([int]$runtime.history_size)
                $histories[$name] = $history
            }

            # Calculate stats for each target
            $statsByName = @{}
            foreach ($target in $targets) {
                $name = [string]$target.name
                $history = Get-OrCreateHistory -Store $histories -TargetName $name
                $statsByName[$name] = Get-Stats -History $history
            }

            # Representative game signal = the best-responding monitor for the chosen game
            $rep = $null
            $repName = ""
            $responding = @()
            foreach ($m in $monitors) {
                $st = $statsByName[$m.name]
                if ($null -ne $st.latest_ms) {
                    $responding += [pscustomobject]@{ name = [string]$m.name; stats = $st }
                }
            }
            if ($responding.Count -gt 0) {
                $pick = $responding | Sort-Object { [double]$_.stats.avg_ms } | Select-Object -First 1
                $rep = $pick.stats
                $repName = $pick.name
            }

            # Best route candidate by score
            $bestRoute = $activeRouteName
            if ($routeTargets.Count -gt 0) {
                $routeStats = @{}
                foreach ($rt in $routeTargets) { $routeStats[[string]$rt.name] = $statsByName[[string]$rt.name] }
                $bestRoutePair = $routeStats.GetEnumerator() | Sort-Object { $_.Value.score } | Select-Object -First 1
                $bestRoute = [string]$bestRoutePair.Key
            }

            # Spike detection on the chosen game (compared to its own normal latency)
            if ($null -ne $rep) {
                $spike = Test-IsSpike -Current ([double]$rep.latest_ms) `
                                      -Baseline ([double]$rep.avg_ms) `
                                      -AbsoluteLimit ([double]$thresholds.spike_over_baseline_ms) `
                                      -MultiplierLimit ([double]$thresholds.spike_multiplier)
                if ($spike -or ([double]$rep.loss_percent -gt [double]$thresholds.max_loss_percent)) {
                    $consecutiveSpikes++
                } else {
                    $consecutiveSpikes = 0
                }
            }

            # Switch route if a better one is found and cooldown has elapsed
            $canSwitch = ((Get-Date) - $lastSwitchedAt).TotalSeconds -ge [double]$runtime.switch_cooldown_seconds
            if ($bestRoute -ne $activeRouteName -and $canSwitch) {
                $prevRoute = $activeRouteName
                $activeRouteName = $bestRoute
                $lastSwitchedAt = Get-Date

                $rtMeta = $routeTargets | Where-Object { [string]$_.name -eq $bestRoute } | Select-Object -First 1
                $newProfile = [string]$rtMeta.profile

                $allowWarp = $true
                $allowDns = $true
                if ($null -ne $actions.PSObject.Properties['allow_warp_auto_switch']) {
                    $allowWarp = [bool]$actions.allow_warp_auto_switch
                }
                if ($null -ne $actions.PSObject.Properties['allow_dns_route_switch']) {
                    $allowDns = [bool]$actions.allow_dns_route_switch
                }

                $profileSupported = (($newProfile -eq 'warp') -and $script:WarpAvailable -and $allowWarp) `
                    -or ($script:DnsRoutes.ContainsKey($newProfile) -and $script:IsAdmin -and $allowDns) `
                    -or (($newProfile -ne 'warp') -and $profileCommands.ContainsKey($newProfile))

                $reroutes = [bool]$actions.enabled -and [bool]$actions.run_profile_command_on_switch `
                            -and ($newProfile -ne $script:CurrentProfile) -and $profileSupported

                if ($reroutes) {
                    $totalSwitches++
                    Write-Log -Level "WARN" -Message "Route switch (rerouting): $prevRoute -> $bestRoute"
                    Switch-ToProfile -ProfileName $newProfile -ProfileCommands $profileCommands
                } else {
                    Write-Log -Message "Best route now: $bestRoute (no reroute applied; needs admin/WARP or same profile)"
                }
            }

            # Take action if consecutive spikes on the game exceed the threshold
            if ([bool]$actions.enabled -and $consecutiveSpikes -ge [int]$thresholds.consecutive_spikes_for_action) {
                Write-Log -Level "WARN" -Message "$selectedGame spike sustained ($consecutiveSpikes in a row). Taking action..."

                if ([bool]$actions.flush_dns_on_spike) {
                    try {
                        ipconfig /flushdns 2>&1 | Out-Null
                        $totalFlushes++
                        Write-Log -Message "  -> DNS cache flushed"
                    } catch {}
                }

                if ([bool]$actions.apply_tcp_profile -and $script:IsAdmin) {
                    try {
                        netsh int tcp set global autotuninglevel=normal 2>&1 | Out-Null
                        netsh int tcp set global ecncapability=enabled 2>&1 | Out-Null
                        netsh int tcp set global rss=enabled 2>&1 | Out-Null
                        Write-Log -Message "  -> TCP profile re-applied"
                    } catch {}
                }

                $consecutiveSpikes = 0
            }

            # ── Display status ───────────────────────────────────────────────
            Write-Host ""
            Write-Host ("-" * 85) -ForegroundColor DarkGray

            $statusColor = if ($consecutiveSpikes -ge 2) { "Red" } elseif ($consecutiveSpikes -ge 1) { "Yellow" } else { "Green" }
            $repPing = if ($null -eq $rep) { "no-ping" } else { "{0}ms" -f [math]::Round([double]$rep.latest_ms) }
            $warpTag = if ($script:WarpAvailable) { "  warp=$($script:CurrentProfile)" } else { "" }
            Write-Host ("[$(Get-NowStamp)] GAME=$selectedGame  ping=$repPing  route=$activeRouteName  profile=$($script:CurrentProfile)  spikes=$consecutiveSpikes  cycle=$totalCycles  switches=$totalSwitches$warpTag") -ForegroundColor $statusColor

            Write-Host "  Game servers:" -ForegroundColor Cyan
            foreach ($m in $monitors) {
                $name = [string]$m.name
                $st = $statsByName[$name]
                $latest = if ($null -eq $st.latest_ms) { "TIMEOUT" } else { "{0}ms" -f [math]::Round([double]$st.latest_ms) }
                $marker = if ($name -eq $repName) { ">>>" } else { "   " }
                $lineColor = "White"
                if ($null -eq $st.latest_ms) { $lineColor = "DarkGray" }
                elseif ([double]$st.latest_ms -gt ([double]$st.avg_ms + [double]$thresholds.spike_over_baseline_ms)) { $lineColor = "Yellow" }
                elseif ($name -eq $repName) { $lineColor = "Green" }
                Write-Host ("  {0} {1,-28} latest={2,-9} avg={3,6:N1}ms  jitter={4,5:N1}ms  loss={5,5:N1}%" -f $marker, $name, $latest, [double]$st.avg_ms, [double]$st.jitter_ms, [double]$st.loss_percent) -ForegroundColor $lineColor
            }

            Write-Host "  Routes:" -ForegroundColor Cyan
            foreach ($rt in $routeTargets) {
                $name = [string]$rt.name
                $st = $statsByName[$name]
                $latest = if ($null -eq $st.latest_ms) { "TIMEOUT" } else { "{0}ms" -f [math]::Round([double]$st.latest_ms) }
                $marker = if ($name -eq $activeRouteName) { ">>>" } else { "   " }
                $lineColor = "White"
                if ($null -eq $st.latest_ms) { $lineColor = "DarkGray" }
                elseif ($name -eq $activeRouteName) { $lineColor = "Green" }
                Write-Host ("  {0} {1,-28} latest={2,-9} avg={3,6:N1}ms  jitter={4,5:N1}ms  loss={5,5:N1}%  score={6,7:N1}" -f $marker, $name, $latest, [double]$st.avg_ms, [double]$st.jitter_ms, [double]$st.loss_percent, [double]$st.score) -ForegroundColor $lineColor
            }
        } catch {
            Write-Log -Level "ERROR" -Message ("Runtime error: " + $_.Exception.Message)
        }

        Start-Sleep -Milliseconds ([int]([double]$runtime.interval_seconds * 1000))
    }
} finally {
    Restore-OriginalDns
    Write-Log -Message "Stabilizer stopped."
}
