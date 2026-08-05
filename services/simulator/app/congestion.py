"""Time-of-day/day-of-week congestion multiplier applied to a segment's real
OSRM free-flow baseline speed. See docs/IMPLEMENTATION_ARCHITECTURE.md §5.2 —
this is a hand-tuned placeholder for calibration against real published PRTC/
PUNBUS/CTU timetables (§5.4), not fit to any real timing data yet. Flagged here
rather than presented as validated.
"""
from __future__ import annotations

_PEAK_HOURS = {8, 9, 17, 18}
_SHOULDER_HOURS = {7, 10, 16, 19}
_WEEKEND_DOWS = {5, 6}  # Python weekday(): Mon=0 .. Sun=6


def congestion_multiplier(hour: int, dow: int) -> float:
    """Multiplier applied to a segment's real free-flow (OSRM baseline) speed.
    <1.0 means slower than free-flow (congested); never expected to exceed 1.0.
    """
    if hour in _PEAK_HOURS:
        base = 0.55
    elif hour in _SHOULDER_HOURS:
        base = 0.75
    else:
        base = 0.95

    if dow in _WEEKEND_DOWS:
        base = min(1.0, base + 0.15)  # lighter weekend traffic

    return base
