"""Trains the ETA segment-duration model (docs/IMPLEMENTATION_ARCHITECTURE.md §6.2),
evaluates it against the time-based split required by §5.4, and exports:

    services/ml-service/artifacts/eta_model.onnx
    services/ml-service/artifacts/metrics.json

Usage:
    python -m train.train_eta --label mohali-tricity
    python -m train.train_eta --label mohali-tricity --smoke   # partial corpus, small split

`--smoke` is for iterating on this script against a still-generating backfill; it
lets dataset.build_dataset scale the split down to whatever days exist instead of
requiring the full 90. Do not report --smoke metrics.json as the real result — the
time-based split it produces is too short to mean anything.
"""
from __future__ import annotations

import argparse
import json
import logging
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.features import FEATURE_COLUMNS  # noqa: E402
from train.dataset import build_dataset  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("train_eta")

ARTIFACTS_DIR = Path(__file__).resolve().parents[1] / "artifacts"
HORIZON_BUCKETS_SEC = [(0, 120), (120, 300), (300, 600), (600, float("inf"))]
HORIZON_LABELS = ["0-2min", "2-5min", "5-10min", "10min+"]


def _naive_baseline_sec(row) -> float:
    """Exactly `models/eta.py`'s current fallback formula, applied per test row — the
    live-today behavior this model is meant to beat."""
    avg_speed = max(row["segment_avg_speed_7d"], 1.0)
    return row["distance_to_stop_m"] / avg_speed + row["current_delay_sec"]


def _mae(actual: np.ndarray, predicted: np.ndarray) -> float:
    return float(np.mean(np.abs(actual - predicted)))


def _git_sha() -> str | None:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=Path(__file__).resolve().parents[3],
            capture_output=True, text=True, timeout=5, check=True,
        )
        return out.stdout.strip()
    except Exception:
        return None


def _horizon_eval(test_frame, model, feature_cols: list[str]) -> dict:
    """Reconstructs cumulative multi-segment ETAs within each test trip — sum of
    predicted segment durations plus dwell priors from a given point to each
    downstream stop — and buckets error by actual horizon, per docs §6.2 ("report MAE
    bucketed by horizon, since a single aggregate MAE hides the near-term error
    passengers feel"). Evaluated for the model and the naive baseline identically so
    the comparison is apples-to-apples.

    `actual_cum` uses the trip's REAL observed dwell times (actual_dwell_at_upcoming_stop_sec,
    ground truth, never a feature) — `duration_sec` alone is pure travel time between
    stops and excludes dwell, so summing it across segments without adding real
    intervening dwell would understate true elapsed time. `pred_cum`/`naive_cum` use
    the historical dwell *prior* instead, since neither predictor can know the
    future dwell — same asymmetry a live system would have.

    Dwell at an intermediate stop is charged when *departing* it (before the next
    segment's travel time), not when arriving — arrival at a stop doesn't require
    waiting through that stop's own dwell.
    """
    buckets_model: dict[str, list[float]] = {label: [] for label in HORIZON_LABELS}
    buckets_naive: dict[str, list[float]] = {label: [] for label in HORIZON_LABELS}

    for trip_id, grp in test_frame.groupby("trip_id", sort=False):
        grp = grp.sort_values("sequence").reset_index(drop=True)
        if len(grp) < 2:
            continue
        X = grp[feature_cols].to_numpy(dtype="float32")
        pred_durations = model.predict(X)
        actual_durations = grp["duration_sec"].to_numpy()
        actual_dwells = grp["actual_dwell_at_upcoming_stop_sec"].to_numpy()
        naive_durations = grp.apply(_naive_baseline_sec, axis=1).to_numpy()
        dwell_priors = grp["upcoming_stop_dwell_prior_sec"].to_numpy()

        n = len(grp)
        for start in range(n):
            actual_cum = 0.0
            pred_cum = 0.0
            naive_cum = 0.0
            for idx, j in enumerate(range(start, n)):
                if idx > 0:
                    actual_cum += actual_dwells[j - 1]
                    pred_cum += dwell_priors[j - 1]
                    naive_cum += dwell_priors[j - 1]
                actual_cum += actual_durations[j]
                pred_cum += max(pred_durations[j], 0.0)
                naive_cum += max(naive_durations[j], 0.0)
                for lo, hi in HORIZON_BUCKETS_SEC:
                    if lo <= actual_cum < hi:
                        label = HORIZON_LABELS[HORIZON_BUCKETS_SEC.index((lo, hi))]
                        buckets_model[label].append(abs(actual_cum - pred_cum))
                        buckets_naive[label].append(abs(actual_cum - naive_cum))
                        break

    def summarize(buckets: dict[str, list[float]]) -> dict:
        return {
            label: {"mae_sec": round(float(np.mean(v)), 1) if v else None, "n": len(v)}
            for label, v in buckets.items()
        }

    return {"model": summarize(buckets_model), "naive_baseline": summarize(buckets_naive)}


def main() -> None:
    parser = argparse.ArgumentParser(description="Train the SetuTrack ETA segment-duration model")
    parser.add_argument("--label", default="mohali-tricity")
    parser.add_argument("--train-days", type=int, default=60)
    parser.add_argument("--val-days", type=int, default=15)
    parser.add_argument("--test-days", type=int, default=15)
    parser.add_argument("--smoke", action="store_true", help="allow a scaled-down split against a partial corpus")
    args = parser.parse_args()

    dataset = build_dataset(args.label, args.train_days, args.val_days, args.test_days)
    frame = dataset.frame
    if frame.empty:
        logger.error("no training rows produced — is data/backfill/%s/stop_events.csv populated?", args.label)
        sys.exit(1)

    if not args.smoke and (dataset.train_days < args.train_days or dataset.test_days < args.test_days):
        logger.error(
            "corpus doesn't cover the full requested split (got %d/%d/%d train/val/test days) — "
            "pass --smoke to run anyway, or wait for the full backfill",
            dataset.train_days, dataset.val_days, dataset.test_days,
        )
        sys.exit(1)

    import lightgbm as lgb

    train = frame[frame["split"] == "train"]
    val = frame[frame["split"] == "val"]
    test = frame[frame["split"] == "test"]
    feature_cols = list(FEATURE_COLUMNS)

    X_train, y_train = train[feature_cols].to_numpy(dtype="float32"), train["duration_sec"].to_numpy()
    X_val, y_val = val[feature_cols].to_numpy(dtype="float32"), val["duration_sec"].to_numpy()
    X_test, y_test = test[feature_cols].to_numpy(dtype="float32"), test["duration_sec"].to_numpy()

    logger.info("training on %d rows, validating on %d, testing on %d", len(train), len(val), len(test))

    model = lgb.LGBMRegressor(
        n_estimators=500, learning_rate=0.05, max_depth=6, num_leaves=31,
        min_child_samples=20, verbosity=-1,
    )
    model.fit(
        X_train, y_train,
        eval_set=[(X_val, y_val)],
        eval_metric="mae",
        callbacks=[lgb.early_stopping(30, verbose=False), lgb.log_evaluation(0)],
    )

    pred_test = model.predict(X_test)
    naive_test = test.apply(_naive_baseline_sec, axis=1).to_numpy()

    per_segment_mae_model = _mae(y_test, pred_test)
    per_segment_mae_naive = _mae(y_test, naive_test)
    horizon = _horizon_eval(test, model, feature_cols)

    importances = dict(zip(feature_cols, [float(x) for x in model.feature_importances_]))

    ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)

    from onnxmltools.convert import convert_lightgbm
    from onnxmltools.convert.common.data_types import FloatTensorType

    onnx_model = convert_lightgbm(model, initial_types=[("input", FloatTensorType([None, len(feature_cols)]))])
    onnx_path = ARTIFACTS_DIR / "eta_model.onnx"
    onnx_path.write_bytes(onnx_model.SerializeToString())

    metrics = {
        "trained_at": datetime.now(timezone.utc).isoformat(),
        "git_sha": _git_sha(),
        "smoke_run": args.smoke,
        "snapshot_label": args.label,
        "feature_columns": feature_cols,
        "row_counts": {"train": len(train), "val": len(val), "test": len(test)},
        "training_window_days": {"train": dataset.train_days, "val": dataset.val_days, "test": dataset.test_days},
        "historical_stat_fallback_counts": dataset.fallback_counts,
        "per_segment_mae_sec": {"model": round(per_segment_mae_model, 1), "naive_baseline": round(per_segment_mae_naive, 1)},
        "per_segment_improvement_pct": round(
            100 * (per_segment_mae_naive - per_segment_mae_model) / per_segment_mae_naive, 1
        ) if per_segment_mae_naive else None,
        "horizon_bucketed_mae_sec": horizon,
        "feature_importance": importances,
    }
    (ARTIFACTS_DIR / "metrics.json").write_text(json.dumps(metrics, indent=2), encoding="utf-8")

    logger.info("wrote %s", onnx_path)
    logger.info("per-segment MAE: model=%.1fs naive=%.1fs (%.1f%% improvement)",
                per_segment_mae_model, per_segment_mae_naive, metrics["per_segment_improvement_pct"] or 0.0)
    for label in HORIZON_LABELS:
        m = horizon["model"][label]
        n = horizon["naive_baseline"][label]
        logger.info("  horizon %-8s model=%s naive=%s (n=%s)", label, m["mae_sec"], n["mae_sec"], m["n"])


if __name__ == "__main__":
    main()
