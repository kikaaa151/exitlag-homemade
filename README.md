# Game Ping Stabilizer

A Windows-first, local network monitor and route controller for online games. It is
inspired by the workflow of tools such as ExitLag, but it is an experimental MVP and
is not affiliated with ExitLag, Cloudflare, Riot Games, Valve, or any game publisher.

The stabilizer measures latency, jitter, and packet loss, detects sustained spikes, and
can switch between configured route profiles. It supports any game whose hosts can be
added to `config.json`, including Valorant, League of Legends, World of Tanks, Minecraft,
CS2, and Dota.

## What it does

- Monitors configured game and route hosts with regular ICMP pings.
- Tracks latest latency, rolling average, jitter, packet loss, and a quality score.
- Selects the best-scoring route while using a cooldown to prevent rapid switching.
- Detects sustained latency spikes and can run optional remediation actions.
- Supports Cloudflare WARP, DNS provider switching, VPN commands, and other CLI profiles.
- Saves logs to `logs/stabilizer.log` when using the PowerShell runner.

## Requirements

- Windows 10 or Windows 11.
- PowerShell 5.1 or newer.
- Administrator access for DNS switching, TCP tuning, and the included `run.bat` launcher.
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

Stop the stabilizer with `Ctrl+C`. The PowerShell runner restores the original DNS
settings when it exits after changing them.

### Python runner

Use this fallback when Python is available on the machine:

```powershell
python -m src.valorant_stabilizer.main --config .\config.json
```

If Windows Defender or App Control blocks `python.exe`, use the PowerShell runner instead.

## How routing works

The project does not create a packet tunnel or guarantee a lower ping. It probes the
configured hosts and uses their measurements to decide which configured profile is best.

- **Cloudflare WARP:** runs the configured `warp-cli` command when enabled.
- **DNS route switching:** changes the active adapter's DNS servers between the providers
  in `dns_routes`. This can affect hostname resolution and CDN selection, but it does not
  reroute existing game packets like a VPN or tunnel.
- **Custom profiles:** `profile_commands` can call a VPN, proxy, or other route provider's
  command-line interface.
- **Monitor-only mode:** if the process cannot change routes, it still reports network
  quality and spike information without applying route changes.

## Configuration

The default configuration is in [`config.json`](config.json). Its main sections are:

| Section | Purpose |
| --- | --- |
| `games` | Game names and hosts used for game-specific monitoring. |
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

Keep `switch_cooldown_seconds` high enough to avoid frequent profile changes. A value of
20 or more seconds is a reasonable starting point. Some game servers block ICMP, so a
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

No third-party Python packages are currently required. To run the Python module from a
checkout:

```powershell
python -m src.valorant_stabilizer.main --config .\config.json
```

Future improvements are tracked in [`docs/PLAN.md`](docs/PLAN.md), including traceroute
snapshots, richer trend analysis, and a local dashboard.
