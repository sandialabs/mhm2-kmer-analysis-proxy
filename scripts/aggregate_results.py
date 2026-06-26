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
CSV_SUMMARY_PATTERN = re.compile(r"^proxy_results_summary_ranks_(\d+)\.csv$")


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parent.parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Aggregate proxy_results_summary.csv files from KOKKOS_* run outputs."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=repo_root_from_script(),
        help="Repository root containing KOKKOS_* output directories (default: parent of scripts/)",
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


def load_results_from_csv_dir(csv_dir: Path, root: Path) -> pd.DataFrame:
    rows = []

    for csv_path in sorted(csv_dir.glob("proxy_results_summary_ranks_*.csv")):
        match = CSV_SUMMARY_PATTERN.match(csv_path.name)
        if not match:
            continue

        frame = pd.read_csv(csv_path)
        if frame.empty:
            continue

        row = frame.iloc[0].to_dict()
        row["ranks"] = int(match.group(1))
        row["output_dir"] = str(csv_path.relative_to(root))
        rows.append(row)

    if not rows:
        return pd.DataFrame()

    return pd.DataFrame(rows).sort_values("ranks").reset_index(drop=True)


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


def load_results(root: Path, kokkos_use: Optional[str], backend: Optional[str]) -> pd.DataFrame:
    batch_dir = latest_batch_dir(root)
    if batch_dir is not None:
        csv_dir = batch_dir / "csv"
        if csv_dir.is_dir():
            data = load_results_from_csv_dir(csv_dir, root)
            if not data.empty:
                return data

    rows = []

    for output_dir in iter_output_dirs(root):
        match = OUTPUT_DIR_PATTERN.match(output_dir.name)
        if not match:
            continue

        run_kokkos, run_backend, ranks_str = match.groups()
        if kokkos_use and run_kokkos != kokkos_use:
            continue
        if backend and run_backend != backend:
            continue

        csv_path = output_dir / "proxy_results_summary.csv"
        if not csv_path.is_file():
            continue

        frame = pd.read_csv(csv_path)
        if frame.empty:
            continue

        row = frame.iloc[0].to_dict()
        row["ranks"] = int(ranks_str)
        row["kokkos_use"] = run_kokkos
        row["backend"] = run_backend
        row["output_dir"] = str(output_dir.relative_to(root))
        rows.append(row)

    if not rows:
        return pd.DataFrame()

    result = pd.DataFrame(rows)
    result = result.sort_values("ranks").reset_index(drop=True)
    return result


def plot_results(data: pd.DataFrame, title_suffix: str, output: Optional[Path], show: bool) -> None:
    pipeline_col = "Pipeline timing (seconds)"
    memory_col = "Peak Memory (GB)"

    for column in (pipeline_col, memory_col):
        if column not in data.columns:
            sys.exit(f"Missing column '{column}' in aggregated results.")

    plot_data = data.copy()
    plot_data["rank_label"] = plot_data["ranks"].astype(str)

    sns.set_theme(style="whitegrid")
    fig, ax_pipeline = plt.subplots(figsize=(10, 6))
    sns.barplot(
        data=plot_data,
        x="rank_label",
        y=pipeline_col,
        color="steelblue",
        ax=ax_pipeline,
    )
    ax_pipeline.set_xlabel("Number of ranks")
    ax_pipeline.set_ylabel("Pipeline timing (seconds)")
    ax_pipeline.set_title(f"Proxy benchmark{title_suffix}")

    ax_memory = ax_pipeline.twinx()
    sns.lineplot(
        data=plot_data,
        x="rank_label",
        y=memory_col,
        marker="o",
        color="darkred",
        linewidth=2,
        ax=ax_memory,
    )
    ax_memory.set_ylabel("Peak memory (GB)")
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

    data = load_results(root, args.kokkos_use, args.backend)
    if data.empty:
        sys.exit(
            f"No proxy_results_summary CSV files found under results/*/csv in {root}"
        )

    title_parts = []
    if args.kokkos_use:
        title_parts.append(args.kokkos_use)
    if args.backend:
        title_parts.append(args.backend)
    elif len(data["backend"].unique()) == 1:
        title_parts.append(data["backend"].iloc[0])
    title_suffix = f" ({', '.join(title_parts)})" if title_parts else ""

    print(data[["output_dir", "ranks", "Pipeline timing (seconds)", "Peak Memory (GB)"]].to_string(index=False))
    plot_results(data, title_suffix, args.output, args.show)


if __name__ == "__main__":
    main()
