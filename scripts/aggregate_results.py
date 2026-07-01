#!/usr/bin/env python3

import argparse
import re
import sys
from pathlib import Path
from typing import List, Optional

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns


OUTPUT_DIR_PATTERN = re.compile(r"^KOKKOS_(ON|OFF)_(.+)_ranks_(\d+)$")
RUN_DIR_PATTERN = re.compile(r"^run_(\d+)$")
MERGED_CSV_NAME = "results.csv"
SUMMARY_CSV_NAME = "proxy_results_summary.csv"


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parent.parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Merge proxy_results_summary.csv files from KOKKOS_* run outputs "
            "into csv/results.csv and plot the aggregated results."
        )
    )
    parser.add_argument(
        "batch_dir",
        nargs="?",
        type=Path,
        default=None,
        help=(
            "Results batch directory containing KOKKOS_* run outputs "
            "(default: latest under <root>/results/)"
        ),
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=repo_root_from_script(),
        help="Repository root used to resolve relative paths (default: parent of scripts/)",
    )
    parser.add_argument(
        "--kokkos-use",
        choices=("KOKKOS_ON", "KOKKOS_OFF"),
        default=None,
        help="Only include runs for this Kokkos configuration",
    )
    parser.add_argument(
        "--backend",
        default=None,
        help="Only include runs for this backend (e.g. HIP), matched from directory names",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Save the chart to this file (e.g. proxy_results.png)",
    )
    parser.add_argument(
        "--show",
        action="store_true",
        help="Display the chart interactively",
    )
    return parser.parse_args()


def latest_batch_dir(root: Path) -> Optional[Path]:
    results_root = root / "results"
    if not results_root.is_dir():
        return None
    batch_dirs = [p for p in results_root.iterdir() if p.is_dir()]
    if not batch_dirs:
        return None
    return max(batch_dirs, key=lambda p: p.stat().st_mtime)


def resolve_batch_dir(root: Path, batch_dir: Optional[Path]) -> Path:
    if batch_dir is not None:
        resolved = batch_dir if batch_dir.is_absolute() else (root / batch_dir).resolve()
        if not resolved.is_dir():
            sys.exit(f"Batch directory not found: {resolved}")
        return resolved

    latest = latest_batch_dir(root)
    if latest is None:
        sys.exit(f"No results batch directories found under {root / 'results'}")
    return latest


def normalize_kokkos_use(value: str) -> str:
    if value.startswith("KOKKOS_"):
        return value
    return f"KOKKOS_{value}"


def build_chart_title(
    data: pd.DataFrame,
    kokkos_use: Optional[str] = None,
    backend: Optional[str] = None,
) -> str:
    title_parts = []

    if kokkos_use:
        title_parts.append(normalize_kokkos_use(kokkos_use))
    elif "kokkos_use" in data.columns:
        kokkos_values = data["kokkos_use"].map(normalize_kokkos_use).unique()
        if len(kokkos_values) == 1:
            title_parts.append(kokkos_values[0])

    if backend:
        title_parts.append(backend)
    elif "backend" in data.columns and len(data["backend"].unique()) == 1:
        title_parts.append(data["backend"].iloc[0])

    suffix = f" ({', '.join(title_parts)})" if title_parts else ""
    return f"mhm2 kmer analysis proxy{suffix}"


def iter_run_csvs(output_dir: Path) -> List[tuple[int, Path]]:
    run_csvs: List[tuple[int, Path]] = []

    for subdir in sorted(output_dir.iterdir()):
        if not subdir.is_dir():
            continue

        match = RUN_DIR_PATTERN.match(subdir.name)
        if not match:
            continue

        csv_path = subdir / SUMMARY_CSV_NAME
        if csv_path.is_file():
            run_csvs.append((int(match.group(1)), csv_path))

    if run_csvs:
        return run_csvs

    csv_path = output_dir / SUMMARY_CSV_NAME
    if csv_path.is_file():
        return [(1, csv_path)]

    return []


def append_result_row(
    rows: List[dict],
    csv_path: Path,
    run_idx: int,
    ranks: int,
    run_kokkos_label: str,
    run_backend: str,
    output_dir: Path,
    root: Path,
) -> None:
    frame = pd.read_csv(csv_path)
    if frame.empty:
        return

    row = frame.iloc[0].to_dict()
    row["run"] = run_idx
    row["ranks"] = ranks
    row["kokkos_use"] = run_kokkos_label
    row["backend"] = run_backend
    row["output_dir"] = str(output_dir.relative_to(root))
    rows.append(row)


def merge_csv_files(
    batch_dir: Path,
    root: Path,
    kokkos_use: Optional[str] = None,
    backend: Optional[str] = None,
) -> Optional[Path]:
    rows = []

    for output_dir in sorted(batch_dir.iterdir()):
        if not output_dir.is_dir():
            continue

        match = OUTPUT_DIR_PATTERN.match(output_dir.name)
        if not match:
            continue

        run_kokkos, run_backend, ranks_str = match.groups()
        run_kokkos_label = normalize_kokkos_use(run_kokkos)
        if kokkos_use and run_kokkos_label != normalize_kokkos_use(kokkos_use):
            continue
        if backend and run_backend != backend:
            continue

        ranks = int(ranks_str)
        for run_idx, csv_path in iter_run_csvs(output_dir):
            append_result_row(
                rows,
                csv_path,
                run_idx,
                ranks,
                run_kokkos_label,
                run_backend,
                csv_path.parent,
                root,
            )

    if not rows:
        return None

    csv_dir = batch_dir / "csv"
    csv_dir.mkdir(parents=True, exist_ok=True)
    output_path = csv_dir / MERGED_CSV_NAME

    result = pd.DataFrame(rows).sort_values(["ranks", "run"]).reset_index(drop=True)
    result.to_csv(output_path, index=False)
    print(f"Wrote merged results to {output_path}")
    return output_path


def load_results_from_csv_dir(csv_dir: Path) -> pd.DataFrame:
    results_path = csv_dir / MERGED_CSV_NAME
    if not results_path.is_file():
        return pd.DataFrame()

    frame = pd.read_csv(results_path)
    sort_cols = ["ranks", "run"] if "run" in frame.columns else ["ranks"]
    return frame.sort_values(sort_cols).reset_index(drop=True)


def iter_output_dirs(root: Path) -> List[Path]:
    output_dirs: List[Path] = []

    results_root = root / "results"
    if results_root.is_dir():
        batch_dirs = sorted(p for p in results_root.iterdir() if p.is_dir())
        if batch_dirs:
            batch_dirs = [max(batch_dirs, key=lambda p: p.stat().st_mtime)]
        for batch_dir in batch_dirs:
            for output_dir in sorted(batch_dir.iterdir()):
                if output_dir.is_dir() and OUTPUT_DIR_PATTERN.match(output_dir.name):
                    output_dirs.append(output_dir)

    if not output_dirs:
        for output_dir in sorted(root.iterdir()):
            if output_dir.is_dir() and OUTPUT_DIR_PATTERN.match(output_dir.name):
                output_dirs.append(output_dir)

    return output_dirs


def load_results(
    root: Path,
    batch_dir: Optional[Path],
    kokkos_use: Optional[str],
    backend: Optional[str],
) -> pd.DataFrame:
    resolved_batch_dir = resolve_batch_dir(root, batch_dir)
    merge_csv_files(resolved_batch_dir, root, kokkos_use, backend)

    csv_dir = resolved_batch_dir / "csv"
    if csv_dir.is_dir():
        data = load_results_from_csv_dir(csv_dir)
        if not data.empty:
            return data

    rows = []

    for output_dir in iter_output_dirs(root):
        match = OUTPUT_DIR_PATTERN.match(output_dir.name)
        if not match:
            continue

        run_kokkos, run_backend, ranks_str = match.groups()
        run_kokkos_label = normalize_kokkos_use(run_kokkos)
        if kokkos_use and run_kokkos_label != normalize_kokkos_use(kokkos_use):
            continue
        if backend and run_backend != backend:
            continue

        ranks = int(ranks_str)
        for run_idx, csv_path in iter_run_csvs(output_dir):
            append_result_row(
                rows,
                csv_path,
                run_idx,
                ranks,
                run_kokkos_label,
                run_backend,
                csv_path.parent,
                root,
            )

    if not rows:
        return pd.DataFrame()

    result = pd.DataFrame(rows)
    sort_cols = ["ranks", "run"] if "run" in result.columns else ["ranks"]
    result = result.sort_values(sort_cols).reset_index(drop=True)
    return result


def summarize_by_rank(data: pd.DataFrame, pipeline_col: str, memory_col: str) -> pd.DataFrame:
    grouped = (
        data.groupby("ranks", as_index=False)
        .agg(
            **{
                pipeline_col: (pipeline_col, "mean"),
                f"{pipeline_col} std": (pipeline_col, "std"),
                memory_col: (memory_col, "mean"),
                f"{memory_col} std": (memory_col, "std"),
                "runs": ("run", "count"),
            }
        )
        .sort_values("ranks")
        .reset_index(drop=True)
    )
    return grouped


# Colorblind-friendly Tol palette for dual-axis charts.
PIPELINE_COLOR = "#4477AA"
MEMORY_COLOR = "#EE7733"
PIPELINE_ERR_COLOR = "#336699"
MEMORY_ERR_COLOR = "#D97706"
ERRORBAR_LINEWIDTH = 1.8
ERRORBAR_CAPSIZE = 0.16
ERRORBAR_CAPTHICK = 1.8
ERRORBAR_POINT_CAPSIZE = 5


def plot_results(data: pd.DataFrame, title: str, output: Optional[Path], show: bool) -> None:
    pipeline_col = "Pipeline timing (seconds)"
    memory_col = "Peak Memory (GB)"

    for column in (pipeline_col, memory_col):
        if column not in data.columns:
            sys.exit(f"Missing column '{column}' in aggregated results.")

    plot_data = data.copy()
    plot_data["rank_label"] = plot_data["ranks"].astype(str)
    use_error_bars = "run" in plot_data.columns and plot_data.groupby("ranks")["run"].nunique().max() > 1

    sns.set_theme(style="ticks", context="talk", palette="colorblind")
    fig, ax_pipeline = plt.subplots(figsize=(10, 6))
    sns.barplot(
        data=plot_data,
        x="rank_label",
        y=pipeline_col,
        color=PIPELINE_COLOR,
        edgecolor="white",
        linewidth=0.8,
        errorbar="sd" if use_error_bars else None,
        capsize=ERRORBAR_CAPSIZE if use_error_bars else 0,
        err_kws={"color": PIPELINE_ERR_COLOR, "linewidth": ERRORBAR_LINEWIDTH},
        ax=ax_pipeline,
    )
    ax_pipeline.set_xlabel("Number of ranks")
    ax_pipeline.set_ylabel("Pipeline timing (seconds)", color=PIPELINE_COLOR)
    ax_pipeline.tick_params(axis="y", labelcolor=PIPELINE_COLOR)
    ax_pipeline.set_title(title)
    ax_pipeline.set_axisbelow(True)
    ax_pipeline.grid(
        axis="y",
        color="#D0D0D0",
        linewidth=0.5,
        linestyle="-",
        zorder=0,
    )
    sns.despine(ax=ax_pipeline, right=False)

    ax_memory = ax_pipeline.twinx()
    sns.lineplot(
        data=plot_data,
        x="rank_label",
        y=memory_col,
        marker="o",
        markersize=8,
        color=MEMORY_COLOR,
        linewidth=2.5,
        errorbar="sd" if use_error_bars else None,
        err_style="bars",
        err_kws={
            "ecolor": MEMORY_ERR_COLOR,
            "elinewidth": ERRORBAR_LINEWIDTH,
            "capsize": ERRORBAR_POINT_CAPSIZE,
            "capthick": ERRORBAR_CAPTHICK,
        },
        ax=ax_memory,
    )
    ax_memory.set_ylabel("Peak memory (GB)", color=MEMORY_COLOR)
    ax_memory.tick_params(axis="y", labelcolor=MEMORY_COLOR)
    ax_memory.grid(False)

    fig.tight_layout()

    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        fig.savefig(output, dpi=150, bbox_inches="tight")
        print(f"Wrote chart to {output}")

    if show or not output:
        plt.show()
    else:
        plt.close(fig)


def main() -> None:
    args = parse_args()
    root = args.root.resolve()

    if not root.is_dir():
        sys.exit(f"Repository root not found: {root}")

    data = load_results(root, args.batch_dir, args.kokkos_use, args.backend)
    if data.empty:
        sys.exit(
            f"No {SUMMARY_CSV_NAME} files found in KOKKOS_* directories under "
            f"{resolve_batch_dir(root, args.batch_dir)}"
        )

    title = build_chart_title(data, args.kokkos_use, args.backend)

    pipeline_col = "Pipeline timing (seconds)"
    memory_col = "Peak Memory (GB)"
    if "run" in data.columns and data.groupby("ranks")["run"].nunique().max() > 1:
        summary = summarize_by_rank(data, pipeline_col, memory_col)
        print(summary.to_string(index=False))
    else:
        print(data[["output_dir", "ranks", pipeline_col, memory_col]].to_string(index=False))

    plot_results(data, title, args.output, args.show)


if __name__ == "__main__":
    main()
