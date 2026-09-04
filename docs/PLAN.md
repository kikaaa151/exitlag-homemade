# ExitLag-like MVP Plan (Valorant)

## Goal
Build a local controller that tries to stabilize latency quality for Valorant by:
- Measuring latency, jitter, and loss against multiple targets.
- Scoring and selecting the best route profile.
- Triggering safe remediation when spikes persist.

## What this MVP does
1. Continuous ping monitor for multiple targets.
2. Route-profile selection logic based on quality score.
3. Cooldown-based switching to avoid flapping.
4. Spike detection and optional auto-actions.
5. Config-driven commands for route providers (WARP, VPN, etc).

## What this MVP does not do
- It does not intercept packets or create a true multipath game tunnel.
- It cannot guarantee lower ping than your ISP path.
- It is best used with an existing route provider command (WARP, VPN CLI, etc).

## Next milestones
1. Add traceroute snapshots during spikes.
2. Add UI dashboard (FastAPI + static frontend).
3. Add Riot region auto-discovery from user region presets.
4. Add persistent logs and weekly quality reports.
