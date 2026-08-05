"""Poisson boarding/alighting model per stop. See
docs/IMPLEMENTATION_ARCHITECTURE.md §2.4/§5.2.

KNOWN GAP: `footfall_prior` is 0.0 for every stop in the current mohali-tricity
snapshot (services/geo-ingest's bbox discovery mode skips POI-density enrichment —
see its README's "Known gaps"), so the `footfall_prior` term below currently has
no effect and every stop is modeled as equally busy. The model is written to use
it correctly the moment geo-ingest populates it; until then this is honestly a
flat per-route model, not a per-stop one.
"""
from __future__ import annotations

_PEAK_HOURS = {7, 8, 9, 17, 18, 19}
_WEEKEND_DOWS = {5, 6}


def boarding_lambda(footfall_prior: float, hour: int, dow: int) -> float:
    """Poisson rate for passengers boarding at a stop."""
    rate = 6.0 + 10.0 * footfall_prior
    if hour in _PEAK_HOURS:
        rate *= 2.2
    if dow in _WEEKEND_DOWS:
        rate *= 0.7
    return max(0.1, rate)


def alighting_mu(occupancy: int, footfall_prior: float, hour: int) -> float:
    """Poisson rate for passengers alighting, scaled by how many are already
    aboard (an empty bus can't shed many riders)."""
    rate = 0.15 + 0.1 * footfall_prior
    if hour in _PEAK_HOURS:
        rate *= 1.3
    return max(0.0, occupancy * rate)


def dwell_seconds(boarding: int, alighting: int, rng) -> float:
    """8s base (door open/close) + per-passenger loading time + noise —
    formula from docs/IMPLEMENTATION_ARCHITECTURE.md §5.2."""
    return 8.0 + 1.8 * boarding + 1.1 * alighting + rng.lognormal(0, 0.3)
