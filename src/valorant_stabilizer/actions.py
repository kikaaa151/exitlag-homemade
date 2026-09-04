from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from datetime import datetime
from typing import Dict


@dataclass
class ActionRunner:
    profile_commands: Dict[str, str]

    def _run(self, command: str) -> None:
        subprocess.run(command, shell=True, check=False)

    def flush_dns(self) -> None:
        self._run("ipconfig /flushdns")

    def apply_tcp_profile(self) -> None:
        # Safe defaults that can reduce bursty behavior on some Windows setups.
        commands = [
            "netsh int tcp set global autotuninglevel=normal",
            "netsh int tcp set global ecncapability=enabled",
            "netsh int tcp set global rss=enabled",
            "netsh int tcp set supplemental internet congestionprovider=ctcp",
        ]
        for cmd in commands:
            self._run(cmd)

    def switch_profile(self, profile_name: str) -> None:
        if profile_name not in self.profile_commands:
            return
        self._run(self.profile_commands[profile_name])


def has_admin_rights() -> bool:
    try:
        return bool(os.getuid() == 0)  # type: ignore[attr-defined]
    except AttributeError:
        import ctypes

        return bool(ctypes.windll.shell32.IsUserAnAdmin())


def now_stamp() -> str:
    return datetime.now().strftime("%H:%M:%S")
