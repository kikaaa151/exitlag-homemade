# Game Ping Stabilizer

A Windows-first, local network monitor and route controller for online games. It is
inspired by the workflow of tools such as ExitLag, but it is an experimental MVP and
is not affiliated with ExitLag, Cloudflare, Riot Games, Valve, or any game publisher.

The stabilizer measures latency, jitter, and packet loss and detects sustained spikes.
The PowerShell runner does not automatically switch routes: comparing different public
hosts cannot establish whether a VPN improves your game connection. It supports hosts
added to `config.json`, including Valorant, League of Legends, World of Tanks, Minecraft,
CS2, and Dota.

## What it does

- Monitors configured game and route hosts with regular ICMP pings, plus your router
  (gateway) so spikes are labelled `LOCAL (Wi-Fi/router)` or `UPSTREAM (ISP/route)`.
- Tracks latest latency, rolling average, jitter, packet loss, and a quality score.
- Session stabilization (needs Administrator, undone on `Ctrl+C`):
  pauses Windows Update / Delivery Optimization / BITS downloads, suppresses the periodic
  Wi-Fi scans that cause ping spikes, disables adapter power saving, marks game traffic
  DSCP 46 (prioritized by Wi-Fi WMM and most routers) and sets the game process to High
  priority. Legacy TCP/registry tweaks from older versions are reverted automatically.
- Detects sustained latency spikes; legacy DNS flush/TCP actions are off by default.
- Leaves your existing WARP connection unchanged.
- Provides read-only gateway and Internet diagnostics with `-Diagnose`.
- Saves logs to `logs/stabilizer.log` when using the PowerShell runner.

### If the old version made things worse

Older builds applied persistent changes (ECN on, `TcpAckFrequency=1`, network throttling
off, DNS switching) that stay in Windows after the program exits. Double-click
`revert_tweaks.bat` once (or run `run_stabilizer.ps1 -Revert` as Administrator) and
reboot. `run.bat` also does this automatically when `stabilize.revert_legacy_tweaks`
is true.

## Requirements

- Windows 10 or Windows 11.
- PowerShell 5.1 or newer.
- Administrator access only for legacy system tweaks and the included `run.bat` launcher;
  monitoring and diagnostics work without it.
- Optional: Python 3.10+ for the Python runner. The Python implementation uses only the
  standard library, so `requirements.txt` does not currently require package installation.
- Optional: Cloudflare WARP installed and available as `warp-cli` if you want WARP routing.

## Quick start

### Recommended: PowerShell runner

Open PowerShell in the project directory and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_stabilizer.ps1 -Config .\config.json
```

The script presents a game menu. To select a game directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_stabilizer.ps1 -Game "League of Legends"
```

To monitor all configured games:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_stabilizer.ps1 -Game All
```

You can also double-click `run.bat`. It requests Administrator access and launches the
PowerShell runner with the default configuration.

If administrator launch fails, right-click `run.bat`, choose **Run as administrator**,
and accept the Windows UAC prompt yourself. The startup log should say
`Admin privileges: YES`. The launcher displays elevation errors and no longer relies on
the Windows Server service to detect elevation. Do not run the `.ps1` by double-clicking.
An organization policy or an account without administrator credentials may prevent
elevation; this program cannot bypass that restriction.

Stop the stabilizer with `Ctrl+C`. The PowerShell runner restores the original DNS
settings when it exits after changing them.

### Diagnose stuttering

Run this while the stutter is happening, in a normal PowerShell window:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run_stabilizer.ps1 -Diagnose -SampleCount 30
```

This samples each active IPv4 gateway, `1.1.1.1`, and `8.8.8.8` sequentially, logging
replies and min/max/average/loss summaries to `logs/stabilizer.log`. It changes no
network settings. Optionally pass `-DiagnosticHost "your.actual.server"` with the real
match server's address, if known and pingable. Publisher websites in the bundled config
are not measurements of your match server.

- Gateway spikes: investigate the local link/router; compare Ethernet with Wi-Fi.
- Stable gateway but Internet spikes: check competing downloads/uploads and router
  congestion. Router SQM can help with bufferbloat; persistent upstream issues need ISP investigation.
- Stable probes but game spikes: compare the game's latency/loss display and actual
  server region; the game route may differ from these public probes.

ICMP may be filtered or deprioritized. A short clean sample does not rule out an
intermittent issue, and sequential probes cannot prove simultaneous packet loss.
If trying WARP, compare the same game/region with it on and off between matches.
Changing tunnels mid-match can interrupt the connection.

### Python runner

Use this fallback when Python is available on the machine:

```powershell
python -m src.valorant_stabilizer.main --config .\config.json
```

If Windows Defender or App Control blocks `python.exe`, use the PowerShell runner instead.
The Python runner is a legacy implementation and does not have the new diagnostic mode
or the PowerShell automatic-switching safeguard. Keep `actions.enabled` false for it.

## How routing works

The project does not create a packet tunnel or guarantee a lower ping. All reference
probes use the currently active connection. A fast reply from a DNS provider says
nothing about how fast your game would be through a different VPN path.

The PowerShell runner ignores automatic profile-switch requests, even in older configs.
DNS changes do not reroute an existing match, and TCP tweaks do not fix live UDP jitter.
WARP can change the Internet path, but must be compared manually using the same game
server. Administrator access does not itself improve ping.

Legacy `routes`, `dns_routes`, and `profile_commands` entries remain in the configuration
for compatibility. The default `actions.enabled: false` keeps monitoring read-only.

## Configuration

The default configuration is in [`config.json`](config.json). Its main sections are:

| Section | Purpose |
| --- | --- |
| `games` | Game names, reference hosts, and game process names (for priority/DSCP). |
| `stabilize` | Reversible session actions: pause background downloads, Wi-Fi scan suppression, adapter power saving, DSCP marking, process priority, legacy tweak revert. |
| `routes` | Route candidates, probe hosts, and profile names. |
| `dns_routes` | DNS server pairs associated with DNS profiles. |
| `profile_commands` | Commands used when a route profile is selected. |
| `thresholds` | Spike, packet-loss, and action trigger limits. |
| `actions` | Enables or disables DNS flushes, TCP tuning, and profile commands. |
| `runtime` | Ping interval, rolling history size, and switch cooldown. |

For example, a custom VPN command can be added to `profile_commands`:

```json
{
  "profile_commands": {
    "direct": "echo Using direct route",
    "my_vpn": "my-vpn-cli connect gaming"
  }
}
```

Profile commands and `switch_cooldown_seconds` are legacy settings, not used for automatic
switching by the PowerShell runner. Some game servers block ICMP, so a
timeout does not necessarily mean the game itself is unreachable; add hosts that provide
useful regional signal for your connection.

## Permissions and safety

Some actions require Administrator privileges, especially DNS changes and the TCP profile.
Review `config.json` before running it, particularly any commands under
`profile_commands`. Test changes in a casual or custom match before using them in ranked
play. Disable an action by setting its value to `false` or set `actions.enabled` to `false`.

This tool cannot force a game to use a specific internal server, bypass ISP congestion, or
guarantee better latency. Results depend on your ISP, region, game servers, and the route
providers you configure.

## Project layout

```text
config.json                 Runtime configuration
run.bat                     Administrator launcher
run_stabilizer.ps1          Recommended Windows implementation
src/valorant_stabilizer/    Python implementation and shared concepts
docs/PLAN.md                MVP plan and future work
logs/                       Runtime logs (ignored by Git)
```

## Development

Run the focused PowerShell regression checks without administrator privileges:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Stabilizer.ps1
```

No third-party Python packages are currently required. To run the Python module from a
checkout:

```powershell
python -m src.valorant_stabilizer.main --config .\config.json
```

Future improvements are tracked in [`docs/PLAN.md`](docs/PLAN.md), including traceroute
snapshots, richer trend analysis, and a local dashboard.
