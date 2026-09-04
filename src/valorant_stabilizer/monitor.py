from __future__ import annotations

import re
import statistics
import subprocess
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Deque, Dict, Optional


PING_TIME_RE = re.compile(r"time[=<]([0-9]+)ms", re.IGNORECASE)


@dataclass
class Sample:
    latency_ms: Optional[float]
    timestamp: float


@dataclass
class TargetState:
    history: Deque[Sample]


@dataclass
class Stats:
    avg_ms: float
    jitter_ms: float
    loss_percent: float
    score: float
    latest_ms: Optional[float]


@dataclass
class Monitor:
    history_size: int
    states: Dict[str, TargetState] = field(default_factory=dict)

    def ensure_target(self, target_name: str) -> None:
        if target_name not in self.states:
            self.states[target_name] = TargetState(history=deque(maxlen=self.history_size))

    def ping_once(self, host: str, timeout_ms: int = 900) -> Optional[float]:
        cmd = ["ping", "-n", "1", "-w", str(timeout_ms), host]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        out = (proc.stdout or "") + "\n" + (proc.stderr or "")

        match = PING_TIME_RE.search(out)
        if not match:
            return None
        return float(match.group(1))

    def push(self, target_name: str, latency_ms: Optional[float]) -> None:
        self.ensure_target(target_name)
        self.states[target_name].history.append(Sample(latency_ms=latency_ms, timestamp=time.time()))

    def get_stats(self, target_name: str) -> Stats:
        self.ensure_target(target_name)
        history = list(self.states[target_name].history)
        if not history:
            return Stats(avg_ms=9999.0, jitter_ms=9999.0, loss_percent=100.0, score=9999.0, latest_ms=None)

        latencies = [s.latency_ms for s in history if s.latency_ms is not None]
        misses = len([s for s in history if s.latency_ms is None])

        if not latencies:
            return Stats(avg_ms=9999.0, jitter_ms=9999.0, loss_percent=100.0, score=9999.0, latest_ms=None)

        avg = statistics.fmean(latencies)
        jitter = 0.0
        if len(latencies) > 1:
            diffs = [abs(b - a) for a, b in zip(latencies, latencies[1:])]
            jitter = statistics.fmean(diffs)

        loss = (misses / len(history)) * 100.0
        score = avg + (jitter * 1.7) + (loss * 6.0)
        return Stats(
            avg_ms=avg,
            jitter_ms=jitter,
            loss_percent=loss,
            score=score,
            latest_ms=history[-1].latency_ms,
        )
