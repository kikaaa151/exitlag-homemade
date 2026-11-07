param(
    [string]$Config = "$PSScriptRoot\config.json",
    [string]$LogPath = "$PSScriptRoot\logs\stabilizer.log",
    [string]$Game = "",
    [switch]$Diagnose,
    [switch]$Revert,
    [ValidateRange(2, 120)][int]$SampleCount = 20,
    [string]$DiagnosticHost = ""
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
        if ($LASTEXITCODE -ne 0) { return "error" }
        if ($output -match '\bDisconnected\b') { return "disconnected" }
        if ($output -match '\bConnected\b') { return "connected" }
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

# ── Legacy tweak revert ──────────────────────────────────────────────────────
# Older versions of this tool applied persistent TCP/registry changes and
# switched DNS repeatedly. These helpers put Windows back to its defaults.

$script:TcpInterfacesKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
$script:MultimediaKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"

function Test-LegacyTweaksPresent {
    try {
        $mm = Get-ItemProperty -Path $script:MultimediaKey -ErrorAction SilentlyContinue
        if ($mm) {
            $nti = [int64]$mm.NetworkThrottlingIndex
            if ($nti -eq -1 -or $nti -eq 4294967295 -or ([int64]$mm.SystemResponsiveness) -eq 0) { return $true }
        }
        foreach ($sub in @(Get-ChildItem -Path $script:TcpInterfacesKey -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $p.TcpAckFrequency -or $null -ne $p.TCPNoDelay) { return $true }
        }
        $tcp = (netsh int tcp show global 2>&1 | Out-String)
        if ($tcp -match 'ECN Capability\s*:\s*enabled' -or $tcp -match 'Initial RTO\s*:\s*2000') { return $true }
    } catch {}
    return $false
}

function Restore-WindowsNetworkDefaults {
    param([hashtable]$KnownDnsSets)

    if (-not $script:IsAdmin) {
        Write-Log -Level "WARN" -Message "Reverting old tweaks requires Administrator; skipped."
        return $false
    }

    Write-Log -Message "Reverting network tweaks left by older versions to Windows defaults..."

    $tcpDefaults = @(
        "netsh int tcp set global autotuninglevel=normal",
        "netsh int tcp set global ecncapability=disabled",
        "netsh int tcp set global timestamps=disabled",
        "netsh int tcp set global nonsackrttresiliency=disabled",
        "netsh int tcp set global initialRto=1000",
        "netsh int tcp set global rss=enabled"
    )
    foreach ($c in $tcpDefaults) {
        try { cmd /c $c 2>&1 | Out-Null } catch {}
    }
    Write-Log -Message "  TCP globals: ECN off, initial RTO 1000 ms, auto-tuning normal (Windows defaults)"

    $removed = 0
    foreach ($sub in @(Get-ChildItem -Path $script:TcpInterfacesKey -ErrorAction SilentlyContinue)) {
        foreach ($valueName in @("TcpAckFrequency", "TCPNoDelay")) {
            try {
                $p = Get-ItemProperty -Path $sub.PSPath -Name $valueName -ErrorAction SilentlyContinue
                if ($null -ne $p) {
                    Remove-ItemProperty -Path $sub.PSPath -Name $valueName -ErrorAction Stop
                    $removed++
                }
            } catch {}
        }
    }
    if ($removed -gt 0) {
        Write-Log -Message "  Removed TcpAckFrequency/TCPNoDelay from $removed interface value(s); takes effect after reboot"
    }

    try {
        Set-ItemProperty -Path $script:MultimediaKey -Name "NetworkThrottlingIndex" -Value 10 -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $script:MultimediaKey -Name "SystemResponsiveness" -Value 20 -Type DWord -ErrorAction Stop
        Write-Log -Message "  Multimedia scheduler: NetworkThrottlingIndex=10, SystemResponsiveness=20 (Windows defaults)"
    } catch {
        Write-Log -Level "WARN" -Message "  Could not restore multimedia scheduler values: $($_.Exception.Message)"
    }

    # Only reset DNS when it still points at a server set this tool used to apply.
    try {
        $ifIndex = Get-ActiveAdapterIndex
        if ($null -ne $ifIndex) {
            $current = @((Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
            $matchesKnown = $false
            foreach ($set in $KnownDnsSets.Values) {
                if ($current.Count -gt 0 -and (@(Compare-Object -ReferenceObject @($set) -DifferenceObject $current).Count -eq 0)) { $matchesKnown = $true }
            }
            if ($matchesKnown) {
                Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ResetServerAddresses -ErrorAction Stop
                ipconfig /flushdns 2>&1 | Out-Null
                Write-Log -Message "  DNS reset to automatic (DHCP); it was still set to $($current -join ', ')"
            }
        }
    } catch {
        Write-Log -Level "WARN" -Message "  DNS check failed: $($_.Exception.Message)"
    }

    Write-Log -Message "Revert complete. Registry TCP changes need a reboot to fully apply."
    return $true
}

# ── Session stabilization (reversible, undone on exit) ───────────────────────

$script:SessionStateFile = Join-Path (Split-Path -Parent $LogPath) "session_state.json"
$script:Session = @{
    stopped_services = @()
    wlan_interface   = $null
    qos_policies     = @()
    boosted_pids     = @()
}

function Save-SessionState {
    try { $script:Session | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:SessionStateFile -Encoding UTF8 } catch {}
}

function Get-ActiveAdapter {
    try {
        $idx = Get-ActiveAdapterIndex
        if ($null -eq $idx) { return $null }
        return Get-NetAdapter -InterfaceIndex $idx -ErrorAction Stop
    } catch { return $null }
}

function Test-IsWifiAdapter {
    param($Adapter)
    if ($null -eq $Adapter) { return $false }
    return (([string]$Adapter.PhysicalMediaType) -match '802\.11|Wireless') -or ([int]$Adapter.InterfaceType -eq 71)
}

function Start-SessionStabilization {
    param($Options, [string[]]$ProcessNames)

    if (-not $script:IsAdmin) {
        Write-Log -Level "WARN" -Message "Stabilization actions need Administrator (use run.bat). Running as monitor only."
        return
    }

    $adapter = Get-ActiveAdapter
    if ($adapter) {
        Write-Log -Message ("Active adapter: {0} ({1})" -f $adapter.Name, $adapter.PhysicalMediaType)
    }

    # Background downloads (Windows Update / Delivery Optimization / BITS) saturate upload and inflate ping.
    if ([bool]$Options.pause_background_downloads) {
        foreach ($svcName in @("DoSvc", "BITS")) {
            try {
                $svc = Get-Service -Name $svcName -ErrorAction Stop
                if ($svc.Status -eq 'Running') {
                    Stop-Service -Name $svcName -Force -ErrorAction Stop
                    $script:Session.stopped_services += $svcName
                    Write-Log -Message "  Paused background download service: $svcName (restored on exit)"
                }
            } catch {
                Write-Log -Level "WARN" -Message "  Could not pause ${svcName}: $($_.Exception.Message)"
            }
        }
    }

    # Windows' periodic Wi-Fi network scans cause 100-500 ms spikes roughly once a minute.
    if ([bool]$Options.suppress_wifi_scanning -and (Test-IsWifiAdapter -Adapter $adapter)) {
        try {
            $out = netsh wlan set autoconfig enabled=no interface="$($adapter.Name)" 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                $script:Session.wlan_interface = [string]$adapter.Name
                Write-Log -Message "  Wi-Fi background scanning suppressed on '$($adapter.Name)' (re-enabled on exit)"
            } else {
                Write-Log -Level "WARN" -Message "  Wi-Fi scan suppression failed: $($out.Trim())"
            }
        } catch {
            Write-Log -Level "WARN" -Message "  Wi-Fi scan suppression failed: $($_.Exception.Message)"
        }
    }

    # Adapter power saving adds wake-up latency; this change is persistent and safe.
    if ([bool]$Options.disable_adapter_power_saving -and $adapter) {
        try {
            Disable-NetAdapterPowerManagement -Name $adapter.Name -NoRestart -ErrorAction Stop
            Write-Log -Message "  Adapter power saving disabled on '$($adapter.Name)' (persistent)"
        } catch {
            Write-Log -Level "WARN" -Message "  Could not change adapter power management: $($_.Exception.Message)"
        }
    }

    # DSCP 46 marks game packets as voice-class; Wi-Fi (WMM) and many routers prioritize them.
    if ([bool]$Options.prioritize_game_traffic_dscp -and $ProcessNames.Count -gt 0) {
        try {
            $qosKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\QoS"
            if (-not (Test-Path $qosKey)) { New-Item -Path $qosKey -Force | Out-Null }
            # Non-domain PCs ignore local QoS policies unless this value is set.
            Set-ItemProperty -Path $qosKey -Name "Do not use NLA" -Value "1" -Type String -ErrorAction Stop
        } catch {
            Write-Log -Level "WARN" -Message "  QoS registry prerequisite failed: $($_.Exception.Message)"
        }
        foreach ($proc in $ProcessNames) {
            $policyName = "GameStabilizer $proc"
            try {
                Remove-NetQosPolicy -Name $policyName -Confirm:$false -ErrorAction SilentlyContinue
                New-NetQosPolicy -Name $policyName -AppPathNameMatchCondition "$proc.exe" -DSCPAction 46 -NetworkProfile All -ErrorAction Stop | Out-Null
                $script:Session.qos_policies += $policyName
            } catch {
                Write-Log -Level "WARN" -Message "  QoS policy for $proc failed: $($_.Exception.Message)"
            }
        }
        if ($script:Session.qos_policies.Count -gt 0) {
            Write-Log -Message ("  Game traffic marked DSCP 46 for: {0} (removed on exit)" -f ($ProcessNames -join ", "))
        }
    }

    Save-SessionState
}

function Update-GameProcessPriority {
    param([string[]]$ProcessNames)
    $found = @()
    foreach ($proc in $ProcessNames) {
        foreach ($p in @(Get-Process -Name $proc -ErrorAction SilentlyContinue)) {
            $found += $p.ProcessName
            try {
                if ($p.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::High) {
                    $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
                    if ($script:Session.boosted_pids -notcontains $p.Id) {
                        $script:Session.boosted_pids += $p.Id
                        Save-SessionState
                    }
                    Write-Log -Message "  Game process '$($p.ProcessName)' (PID $($p.Id)) set to High priority"
                }
            } catch {}
        }
    }
    return ,$found
}

function Stop-SessionStabilization {
    param([hashtable]$State = $script:Session)

    foreach ($svcName in @($State.stopped_services)) {
        try {
            Start-Service -Name $svcName -ErrorAction Stop
            Write-Log -Message "  Restarted service: $svcName"
        } catch {}
    }
    if ($State.wlan_interface) {
        try {
            netsh wlan set autoconfig enabled=yes interface="$($State.wlan_interface)" 2>&1 | Out-Null
            Write-Log -Message "  Wi-Fi auto-config re-enabled on '$($State.wlan_interface)'"
        } catch {}
    }
    foreach ($policy in @($State.qos_policies)) {
        try { Remove-NetQosPolicy -Name $policy -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    }
    if (@($State.qos_policies).Count -gt 0) { Write-Log -Message "  QoS policies removed" }
    foreach ($procId in @($State.boosted_pids)) {
        try {
            $p = Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue
            if ($p) { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal }
        } catch {}
    }
    try { Remove-Item -LiteralPath $script:SessionStateFile -Force -ErrorAction SilentlyContinue } catch {}
}

function Restore-PreviousSessionIfNeeded {
    if (-not (Test-Path -LiteralPath $script:SessionStateFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:SessionStateFile -Raw | ConvertFrom-Json
        $state = @{
            stopped_services = @($raw.stopped_services)
            wlan_interface   = $raw.wlan_interface
            qos_policies     = @($raw.qos_policies)
            boosted_pids     = @($raw.boosted_pids)
        }
        Write-Log -Level "WARN" -Message "Previous session did not exit cleanly; restoring its changes first."
        Stop-SessionStabilization -State $state
    } catch {
        try { Remove-Item -LiteralPath $script:SessionStateFile -Force -ErrorAction SilentlyContinue } catch {}
    }
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

$logDirectory = Split-Path -Parent $LogPath
if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

if ($Diagnose) {
    Write-Log -Message "Read-only diagnostics: $SampleCount pings per host; no administrator access required."
    $diagnosticTargets = @()
    try {
        $adapters = @(Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' })
        foreach ($adapter in $adapters) {
            foreach ($gateway in $adapter.IPv4DefaultGateway) {
                $diagnosticTargets += [pscustomobject]@{
                    name = "Gateway ($($adapter.InterfaceAlias))"
                    host = [string]$gateway.NextHop
                }
            }
        }
    } catch {
        Write-Log -Level "WARN" -Message "Could not discover the gateway: $($_.Exception.Message)"
    }
    if ($diagnosticTargets.Count -eq 0) {
        Write-Log -Level "WARN" -Message "No active IPv4 gateway found; local-link diagnosis is unavailable."
    }
    $diagnosticTargets += [pscustomobject]@{ name = "Internet (Cloudflare)"; host = "1.1.1.1" }
    $diagnosticTargets += [pscustomobject]@{ name = "Internet (Google)"; host = "8.8.8.8" }
    if (-not [string]::IsNullOrWhiteSpace($DiagnosticHost)) {
        $diagnosticTargets += [pscustomobject]@{ name = "User-supplied game host"; host = $DiagnosticHost.Trim() }
    }
    foreach ($target in $diagnosticTargets) {
        Write-Log -Message "Testing $($target.name): $($target.host)"
        & "$env:SystemRoot\System32\PING.EXE" -n $SampleCount -w 1000 $target.host |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace([string]$_)) {
                    Write-Log -Message ([string]$_)
                }
            }
    }
    Write-Log -Message "Gateway spikes suggest the local link/router; stable gateway with Internet spikes suggests an upstream issue."
    Write-Log -Message "ICMP can be filtered or deprioritized. These sequential samples cannot prove where game packet loss occurs."
    Write-Log -Message "Repeat during stuttering; compare with the game's own latency and packet-loss display."
    return
}

if (-not (Test-Path -LiteralPath $Config)) {
    throw "Config file not found: $Config"
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
    $gprocs = @()
    foreach ($pn in @($g.processes)) {
        $ps = [string]$pn
        if (-not [string]::IsNullOrWhiteSpace($ps)) { $gprocs += ($ps.Trim() -replace '\.exe$', '') }
    }
    $games += [pscustomobject]@{ name = $gname.Trim(); hosts = $ghosts; processes = $gprocs }
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

$stabilize = $configRaw.stabilize
if ($null -eq $stabilize) { $stabilize = [pscustomobject]@{ enabled = $false } }

if ($Revert) {
    [void](Restore-WindowsNetworkDefaults -KnownDnsSets $script:DnsRoutes)
    Restore-PreviousSessionIfNeeded
    return
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
$gameProcesses = @()
if ($selectedGame -eq "ALL") {
    foreach ($g in $games) {
        foreach ($h in $g.hosts) {
            $monitors += [pscustomobject]@{ name = ("{0}: {1}" -f $g.name, $h); host = $h; profile = "direct"; role = "monitor" }
        }
        $gameProcesses += @($g.processes)
    }
    Write-Log -Message "Selected game: ALL GAMES (monitoring everything)"
} else {
    $g = $games | Where-Object { [string]$_.name -eq $selectedGame } | Select-Object -First 1
    foreach ($h in $g.hosts) {
        $monitors += [pscustomobject]@{ name = ("{0}: {1}" -f $g.name, $h); host = $h; profile = "direct"; role = "monitor" }
    }
    $gameProcesses += @($g.processes)
    Write-Log -Message "Selected game: $selectedGame"
}
$gameProcesses = @($gameProcesses | Select-Object -Unique)

# Gateway probe: tells local link (Wi-Fi/router) spikes apart from upstream ones.
$gatewayTarget = $null
try {
    $gwCfg = Get-NetIPConfiguration -ErrorAction Stop |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1
    if ($gwCfg) {
        $gwHost = [string]($gwCfg.IPv4DefaultGateway | Select-Object -First 1).NextHop
        if (-not [string]::IsNullOrWhiteSpace($gwHost)) {
            $gatewayTarget = [pscustomobject]@{ name = "Gateway (router)"; host = $gwHost; profile = "direct"; role = "gateway" }
        }
    }
} catch {}

# Combined ping set: game monitors (spike watch) + gateway + route candidates (switchable)
$targets = @()
$targets += $monitors
if ($gatewayTarget) { $targets += $gatewayTarget }
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
    Write-Host "  WARP is installed. Its current connection is left unchanged." -ForegroundColor Green
    Write-Host "  Compare WARP on/off manually between matches, not during play." -ForegroundColor Green
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
    Write-Log -Message "Startup network changes skipped."
}

Restore-PreviousSessionIfNeeded

if ([bool]$stabilize.enabled) {
    if ([bool]$stabilize.revert_legacy_tweaks -and (Test-LegacyTweaksPresent)) {
        [void](Restore-WindowsNetworkDefaults -KnownDnsSets $script:DnsRoutes)
    }
    Write-Log -Message "Applying session stabilization (all changes undone on Ctrl+C)..."
    Start-SessionStabilization -Options $stabilize -ProcessNames $gameProcesses
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
$totalCycles = 0
$totalFlushes = 0

Write-Host ""
Write-Log -Message "Monitoring: $selectedGame  (configured hosts: $($monitors.Count), reference probes: $($routeTargets.Count))"

if ([bool]$actions.enabled) {
    Write-Log -Message "MODE: MONITOR + opted-in legacy DNS flush/TCP actions; no automatic rerouting."
} elseif ([bool]$stabilize.enabled -and $script:IsAdmin) {
    Write-Log -Message "MODE: STABILIZE - background downloads paused, Wi-Fi scan spikes suppressed, game traffic/process prioritized."
} else {
    Write-Log -Message "MODE: MONITOR-ONLY - network settings remain unchanged, including when running as administrator."
}
if ([bool]$actions.enabled -and [bool]$actions.run_profile_command_on_switch) {
    Write-Log -Level "WARN" -Message "Automatic profile switching is disabled: pings to different hosts do not compare direct versus VPN routes."
}
Write-Log -Level "WARN" -Message "DNS changes and TCP tweaks do not fix live UDP game jitter. Administrator access alone cannot stabilize ping."
Write-Log -Message "Configured publisher websites are reference hosts, not necessarily your match server. Use -Diagnose to check the local link and Internet."
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
            $spikeOrigin = ""
            if ($null -ne $rep) {
                $spike = Test-IsSpike -Current ([double]$rep.latest_ms) `
                                      -Baseline ([double]$rep.avg_ms) `
                                      -AbsoluteLimit ([double]$thresholds.spike_over_baseline_ms) `
                                      -MultiplierLimit ([double]$thresholds.spike_multiplier)
                if ($spike -or ([double]$rep.loss_percent -gt [double]$thresholds.max_loss_percent)) {
                    $consecutiveSpikes++
                    if ($gatewayTarget) {
                        $gw = $statsByName[[string]$gatewayTarget.name]
                        $gwSpiking = ($null -eq $gw.latest_ms) -or ([double]$gw.latest_ms -ge 10.0 -and [double]$gw.latest_ms -ge ([double]$gw.avg_ms * 2.0))
                        $spikeOrigin = if ($gwSpiking) { "LOCAL (Wi-Fi/router)" } else { "UPSTREAM (ISP/route)" }
                    }
                } else {
                    $consecutiveSpikes = 0
                }
            }

            if ([bool]$stabilize.enabled -and [bool]$stabilize.boost_game_process_priority -and $gameProcesses.Count -gt 0) {
                $runningGames = Update-GameProcessPriority -ProcessNames $gameProcesses
            } else {
                $runningGames = @()
            }

            if ($bestRoute -ne $activeRouteName) {
                $activeRouteName = $bestRoute
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
            $gameTag = if ($runningGames.Count -gt 0) { "  game_running=$($runningGames -join ',')" } else { "" }
            $originTag = if ($spikeOrigin) { "  spike_origin=$spikeOrigin" } else { "" }
            Write-Host ("[$(Get-NowStamp)] GAME=$selectedGame  reference_ping=$repPing  spikes=$consecutiveSpikes  cycle=$totalCycles$warpTag$gameTag$originTag") -ForegroundColor $statusColor
            if ($spikeOrigin -and $consecutiveSpikes -ge [int]$thresholds.consecutive_spikes_for_action) {
                Write-Log -Level "WARN" -Message "Sustained spike ($consecutiveSpikes). Origin: $spikeOrigin"
            }

            if ($gatewayTarget) {
                $gw = $statsByName[[string]$gatewayTarget.name]
                $gwLatest = if ($null -eq $gw.latest_ms) { "TIMEOUT" } else { "{0}ms" -f [math]::Round([double]$gw.latest_ms) }
                $gwColor = if ($null -eq $gw.latest_ms) { "DarkGray" } elseif ([double]$gw.latest_ms -ge 10.0 -and [double]$gw.latest_ms -ge ([double]$gw.avg_ms * 2.0)) { "Yellow" } else { "White" }
                Write-Host ("  Local link: {0,-28} latest={1,-9} avg={2,6:N1}ms  jitter={3,5:N1}ms  loss={4,5:N1}%" -f "$($gatewayTarget.name) $($gatewayTarget.host)", $gwLatest, [double]$gw.avg_ms, [double]$gw.jitter_ms, [double]$gw.loss_percent) -ForegroundColor $gwColor
            }

            Write-Host "  Configured game reference hosts (not necessarily match servers):" -ForegroundColor Cyan
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

            Write-Host "  Internet reference probes (all use the current connection):" -ForegroundColor Cyan
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
    if ([bool]$stabilize.enabled -and $script:IsAdmin) {
        Write-Log -Message "Undoing session stabilization..."
        Stop-SessionStabilization
    }
    Write-Log -Message "Stabilizer stopped."
}
