from __future__ import annotations

import argparse
import time
from pathlib import Path

from .actions import ActionRunner, has_admin_rights, now_stamp
from .config import AppConfig, load_config
from .monitor import Monitor


def choose_best_target(cfg: AppConfig, mon: Monitor) -> str:
    scored = []
    for target in cfg.targets:
        st = mon.get_stats(target.name)
        scored.append((st.score, target.name))
    scored.sort(key=lambda x: x[0])
    return scored[0][1]


def is_spike(current_ms: float, baseline_ms: float, abs_limit: float, mult_limit: float) -> bool:
    return (current_ms - baseline_ms) >= abs_limit and current_ms >= (baseline_ms * mult_limit)


def print_status(cfg: AppConfig, mon: Monitor, active_target: str, spikes: int) -> None:
    print("-" * 78)
    print(f"[{now_stamp()}] active={active_target} consecutive_spikes={spikes}")
    for target in cfg.targets:
        st = mon.get_stats(target.name)
        latest = "timeout" if st.latest_ms is None else f"{st.latest_ms:.0f}ms"
        marker = "*" if target.name == active_target else " "
        print(
            f"{marker} {target.name:<16} latest={latest:<8} avg={st.avg_ms:>6.1f}ms "
            f"jitter={st.jitter_ms:>6.1f} loss={st.loss_percent:>5.1f}% score={st.score:>7.1f}"
        )


def run_loop(cfg: AppConfig) -> None:
    monitor = Monitor(history_size=cfg.runtime.history_size)
    actions = ActionRunner(profile_commands=cfg.profile_commands)

    last_switched_at = 0.0
    consecutive_spikes = 0

    for target in cfg.targets:
        monitor.ensure_target(target.name)

    active_target = cfg.targets[0].name

    print("Game Ping Stabilizer (multi-game) running. Press Ctrl+C to stop.")
    print(f"Admin privileges: {'yes' if has_admin_rights() else 'no'}")

    while True:
        for target in cfg.targets:
            latency = monitor.ping_once(target.host)
            monitor.push(target.name, latency)

        best_target = choose_best_target(cfg, monitor)
        best_target_meta = next(t for t in cfg.targets if t.name == best_target)

        active_stats = monitor.get_stats(active_target)
        baseline_stats = monitor.get_stats(best_target)

        latest_active = active_stats.latest_ms
        if latest_active is not None:
            if is_spike(
                latest_active,
                baseline_stats.avg_ms,
                cfg.thresholds.spike_over_baseline_ms,
                cfg.thresholds.spike_multiplier,
            ) or (active_stats.loss_percent > cfg.thresholds.max_loss_percent):
                consecutive_spikes += 1
            else:
                consecutive_spikes = 0

        now = time.time()
        can_switch = (now - last_switched_at) >= cfg.runtime.switch_cooldown_seconds
        if best_target != active_target and can_switch:
            active_target = best_target
            last_switched_at = now
            if cfg.actions.enabled and cfg.actions.run_profile_command_on_switch:
                actions.switch_profile(best_target_meta.profile)
                print(f"[{now_stamp()}] profile switch -> {best_target_meta.profile}")

        if cfg.actions.enabled and consecutive_spikes >= cfg.thresholds.consecutive_spikes_for_action:
            if cfg.actions.flush_dns_on_spike:
                actions.flush_dns()
                print(f"[{now_stamp()}] action -> ipconfig /flushdns")
            if cfg.actions.apply_tcp_profile:
                actions.apply_tcp_profile()
                print(f"[{now_stamp()}] action -> netsh tcp profile applied")
            consecutive_spikes = 0

        print_status(cfg, monitor, active_target, consecutive_spikes)
        time.sleep(cfg.runtime.interval_seconds)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Multi-game route and ping stabilizer")
    parser.add_argument(
        "--config",
        type=str,
        default="config.json",
        help="Path to JSON config file",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    cfg_path = Path(args.config)
    cfg = load_config(cfg_path)
    run_loop(cfg)


if __name__ == "__main__":
    main()
