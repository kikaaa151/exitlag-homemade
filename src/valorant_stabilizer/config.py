from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List


@dataclass
class Target:
    name: str
    host: str
    profile: str = "direct"


@dataclass
class Thresholds:
    spike_over_baseline_ms: float = 25.0
    spike_multiplier: float = 1.45
    max_loss_percent: float = 3.0
    consecutive_spikes_for_action: int = 3


@dataclass
class ActionConfig:
    enabled: bool = True
    apply_tcp_profile: bool = False
    flush_dns_on_spike: bool = True
    run_profile_command_on_switch: bool = True


@dataclass
class Runtime:
    interval_seconds: float = 2.0
    history_size: int = 30
    switch_cooldown_seconds: int = 25


@dataclass
class AppConfig:
    targets: List[Target]
    profile_commands: Dict[str, str] = field(default_factory=dict)
    thresholds: Thresholds = field(default_factory=Thresholds)
    actions: ActionConfig = field(default_factory=ActionConfig)
    runtime: Runtime = field(default_factory=Runtime)


DEFAULT_CONFIG = {
    "games": [
        {"name": "League of Legends", "hosts": ["leagueoflegends.com", "riotgames.com"]},
        {"name": "Valorant", "hosts": ["playvalorant.com", "riotgames.com"]},
        {"name": "Minecraft (Hypixel)", "hosts": ["mc.hypixel.net"]},
    ],
    "routes": [
        {"name": "Cloudflare DNS", "host": "1.1.1.1", "profile": "dns_cloudflare"},
        {"name": "Google DNS", "host": "8.8.8.8", "profile": "dns_google"},
        {"name": "Cloudflare WARP", "host": "1.0.0.1", "profile": "warp"},
    ],
    "dns_routes": {
        "dns_cloudflare": ["1.1.1.1", "1.0.0.1"],
        "dns_google": ["8.8.8.8", "8.8.4.4"],
    },
    "profile_commands": {
        "warp": "echo Switch to WARP route here, e.g. warp-cli connect",
    },
    "thresholds": {
        "spike_over_baseline_ms": 25,
        "spike_multiplier": 1.45,
        "max_loss_percent": 3.0,
        "consecutive_spikes_for_action": 3,
    },
    "actions": {
        "enabled": True,
        "apply_tcp_profile": False,
        "flush_dns_on_spike": True,
        "run_profile_command_on_switch": True,
    },
    "runtime": {
        "interval_seconds": 1.5,
        "history_size": 40,
        "switch_cooldown_seconds": 25,
    },
}


def write_default_config(path: Path) -> None:
    path.write_text(json.dumps(DEFAULT_CONFIG, indent=2), encoding="utf-8")


def _targets_from_raw(raw: dict) -> List[Target]:
    # Backward compatible: honor an explicit "targets" list if present.
    if raw.get("targets"):
        return [
            Target(name=item["name"], host=item["host"], profile=item.get("profile", "direct"))
            for item in raw["targets"]
        ]

    # New schema: routes are switchable, each game host is a monitor.
    targets: List[Target] = []
    for route in raw.get("routes", []):
        targets.append(
            Target(
                name=route["name"],
                host=route["host"],
                profile=route.get("profile", "direct"),
            )
        )
    for game in raw.get("games", []):
        for host in game.get("hosts", []):
            targets.append(Target(name=f"{game['name']}: {host}", host=host, profile="direct"))
    return targets


def load_config(path: Path) -> AppConfig:
    if not path.exists():
        write_default_config(path)

    raw = json.loads(path.read_text(encoding="utf-8"))

    targets = _targets_from_raw(raw)

    if not targets:
        raise ValueError("Config must include 'games'/'routes' (or a legacy 'targets' list).")

    thresholds_raw = raw.get("thresholds", {})
    actions_raw = raw.get("actions", {})
    runtime_raw = raw.get("runtime", {})

    return AppConfig(
        targets=targets,
        profile_commands=raw.get("profile_commands", {}),
        thresholds=Thresholds(
            spike_over_baseline_ms=float(thresholds_raw.get("spike_over_baseline_ms", 25.0)),
            spike_multiplier=float(thresholds_raw.get("spike_multiplier", 1.45)),
            max_loss_percent=float(thresholds_raw.get("max_loss_percent", 3.0)),
            consecutive_spikes_for_action=int(
                thresholds_raw.get("consecutive_spikes_for_action", 3)
            ),
        ),
        actions=ActionConfig(
            enabled=bool(actions_raw.get("enabled", True)),
            apply_tcp_profile=bool(actions_raw.get("apply_tcp_profile", False)),
            flush_dns_on_spike=bool(actions_raw.get("flush_dns_on_spike", True)),
            run_profile_command_on_switch=bool(
                actions_raw.get("run_profile_command_on_switch", True)
            ),
        ),
        runtime=Runtime(
            interval_seconds=float(runtime_raw.get("interval_seconds", 1.5)),
            history_size=int(runtime_raw.get("history_size", 40)),
            switch_cooldown_seconds=int(runtime_raw.get("switch_cooldown_seconds", 25)),
        ),
    )
