"""Prometheus metrics in the text exposition format, without a client library.

Week 8's Prometheus can scrape /metrics. The pipeline's Verify stage reads the build_info line
to confirm which release is answering. Paths outside the known routes are counted as "other",
so a scan of random URLs cannot create unlimited label values.
"""

from __future__ import annotations

import threading
import time
from collections import Counter

from .config import Config

KNOWN_PATHS = frozenset({"/", "/healthz", "/readyz", "/version", "/metrics"})


def _label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


class Metrics:
    def __init__(self, config: Config, clock=time.time) -> None:
        self._config = config
        self._started = clock()
        self._lock = threading.Lock()
        self._requests: Counter[tuple[str, int]] = Counter()

    def observe(self, path: str, status: int) -> None:
        key = (path if path in KNOWN_PATHS else "other", status)
        with self._lock:
            self._requests[key] += 1

    def render(self) -> str:
        c = self._config
        lines = [
            "# HELP davine_webapp_build_info The release this process is running. Always 1.",
            "# TYPE davine_webapp_build_info gauge",
            f'davine_webapp_build_info{{version="{_label(c.version)}",commit="{_label(c.commit)}",'
            f'env_mode="{_label(c.env_mode)}"}} 1',
            "# HELP davine_webapp_start_time_seconds When this process started, in Unix time.",
            "# TYPE davine_webapp_start_time_seconds gauge",
            f"davine_webapp_start_time_seconds {self._started:.3f}",
            "# HELP davine_webapp_http_requests_total HTTP requests answered, by path and status.",
            "# TYPE davine_webapp_http_requests_total counter",
        ]
        with self._lock:
            counts = sorted(self._requests.items())
        for (path, status), count in counts:
            labels = f'path="{_label(path)}",code="{status}"'
            lines.append(f"davine_webapp_http_requests_total{{{labels}}} {count}")
        return "\n".join(lines) + "\n"
