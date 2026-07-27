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
        "--compare",
        action="store_true",
        help=(
            "Compare KOKKOS_ON and KOKKOS_OFF side by side, loading the latest "
            "results batch for each configuration under <root>/results/"
        ),
    )
    parser.add_argument(
        "--results-group",
        default=None,
        help="Only search batch dirs under results/<GROUP>/ (e.g. MI300, H100)",
    )
    parser.add_argument(
        "--backend",
        default=None,
        help="Only include runs for this backend (e.g. HIP), detected from mhm2.log when present",
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


def _is_batch_dir(path: Path) -> bool:
    """A results batch contains one or more KOKKOS_*_ranks_* run directories."""
    if not path.is_dir():
        return False
    try:
        for child in path.iterdir():
            if child.is_dir() and OUTPUT_DIR_PATTERN.match(child.name):
                return True
    except OSError:
        return False
    return False


def iter_batch_dirs(root: Path, results_group: Optional[str] = None) -> List[Path]:
    """Find batch dirs under results/, including results/<GROUP>/results_*."""
    results_root = root / "results"
    if results_group:
        results_root = results_root / results_group
    if not results_root.is_dir():
        return []

    batch_dirs: List[Path] = []
    for path in results_root.iterdir():
        if not path.is_dir():
            continue
        if _is_batch_dir(path):
            batch_dirs.append(path)
            continue
        # Backend grouping: results/CUDA/results_TS_HASH/
        try:
            for child in path.iterdir():
                if _is_batch_dir(child):
                    batch_dirs.append(child)
        except OSError:
            continue

    return batch_dirs


def latest_batch_dir(root: Path) -> Optional[Path]:
    batch_dirs = iter_batch_dirs(root)
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


def detect_backend_from_log(run_dir: Path) -> Optional[str]:
    log_path = run_dir / "mhm2.log"
    if not log_path.is_file():
        return None
    try:
        with log_path.open(encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                if "ENABLE_HIP=ON" in line:
                    return "HIP"
                if "ENABLE_CUDA=ON" in line:
                    return "CUDA"
    except OSError:
        return None
    return None


def resolve_backend(run_dir: Path, dir_backend: str) -> str:
    return detect_backend_from_log(run_dir) or dir_backend


def output_dir_matches_backend(
    output_dir: Path,
    dir_backend: str,
    backend: Optional[str],
) -> bool:
    if not backend:
        return True
    for _, csv_path in iter_run_csvs(output_dir):
        if resolve_backend(csv_path.parent, dir_backend) == backend:
            return True
    return False


def display_impl_label(kokkos_use: str, backend: Optional[str] = None) -> str:
    """Map internal KOKKOS_ON/OFF labels to chart legend names."""
    normalized = normalize_kokkos_use(kokkos_use)
    backend_label = backend.upper() if backend else "NATIVE"
    # Host builds: classic kcount_cpu vs Kokkos OpenMP ExecutionSpace.
    if backend_label == "CPU":
        if normalized == "KOKKOS_ON":
            return "Kokkos::OpenMP"
        if normalized == "KOKKOS_OFF":
            return "Serial"
    if normalized == "KOKKOS_ON":
        return f"KOKKOS::{backend_label}" if backend else "KOKKOS"
    if normalized == "KOKKOS_OFF":
        return backend_label
    return normalized


def build_chart_title(
    data: pd.DataFrame,
    kokkos_use: Optional[str] = None,
    backend: Optional[str] = None,
) -> str:
    resolved_backend = backend
    if resolved_backend is None and "backend" in data.columns and len(data["backend"].unique()) == 1:
        resolved_backend = str(data["backend"].iloc[0])

    resolved_kokkos = kokkos_use
    if resolved_kokkos is None and "kokkos_use" in data.columns:
        kokkos_values = data["kokkos_use"].map(normalize_kokkos_use).unique()
        if len(kokkos_values) == 1:
            resolved_kokkos = kokkos_values[0]

    # Prefer human-facing labels (Serial / Kokkos::OpenMP on CPU).
    if resolved_kokkos is not None:
        label = display_impl_label(resolved_kokkos, resolved_backend)
        return f"MHM2 Kmer Analysis Proxy ({label})"

    if resolved_backend:
        return f"MHM2 Kmer Analysis Proxy ({resolved_backend})"
    return "MHM2 Kmer Analysis Proxy"


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
        if not output_dir_matches_backend(output_dir, run_backend, backend):
            continue

        ranks = int(ranks_str)
        for run_idx, csv_path in iter_run_csvs(output_dir):
            actual_backend = resolve_backend(csv_path.parent, run_backend)
            if backend and actual_backend != backend:
                continue
            append_result_row(
                rows,
                csv_path,
                run_idx,
                ranks,
                run_kokkos_label,
                actual_backend,
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

    batch_dirs = iter_batch_dirs(root)
    if batch_dirs:
        latest = max(batch_dirs, key=lambda p: p.stat().st_mtime)
        for output_dir in sorted(latest.iterdir()):
            if output_dir.is_dir() and OUTPUT_DIR_PATTERN.match(output_dir.name):
                output_dirs.append(output_dir)

    if not output_dirs:
        for output_dir in sorted(root.iterdir()):
            if output_dir.is_dir() and OUTPUT_DIR_PATTERN.match(output_dir.name):
                output_dirs.append(output_dir)

    return output_dirs


def batch_has_kokkos_config(
    batch_dir: Path,
    kokkos_use: str,
    backend: Optional[str] = None,
) -> bool:
    for output_dir in batch_dir.iterdir():
        if not output_dir.is_dir():
            continue

        match = OUTPUT_DIR_PATTERN.match(output_dir.name)
        if not match:
            continue

        run_kokkos, run_backend, _ = match.groups()
        if normalize_kokkos_use(run_kokkos) != normalize_kokkos_use(kokkos_use):
            continue
        if not output_dir_matches_backend(output_dir, run_backend, backend):
            continue
        return True

    return False


def load_batch_data(
    batch_dir: Path,
    root: Path,
    kokkos_use: Optional[str] = None,
    backend: Optional[str] = None,
) -> pd.DataFrame:
    merge_csv_files(batch_dir, root, kokkos_use, backend)

    data = load_results_from_csv_dir(batch_dir / "csv")
    if data.empty:
        return data

    if kokkos_use and "kokkos_use" in data.columns:
        data = data[data["kokkos_use"] == normalize_kokkos_use(kokkos_use)]
    if backend and "backend" in data.columns:
        data = data[data["backend"] == backend]

    sort_cols = ["ranks", "run"] if "run" in data.columns else ["ranks"]
    return data.sort_values(sort_cols).reset_index(drop=True)


def load_compare_results(
    root: Path,
    backend: Optional[str] = None,
    results_group: Optional[str] = None,
) -> pd.DataFrame:
    batch_dirs = sorted(
        iter_batch_dirs(root, results_group),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not batch_dirs:
        return pd.DataFrame()

    frames: List[pd.DataFrame] = []
    for kokkos in ("KOKKOS_OFF", "KOKKOS_ON"):
        for batch_dir in batch_dirs:
            if not batch_has_kokkos_config(batch_dir, kokkos, backend):
                continue

            frame = load_batch_data(batch_dir, root, kokkos, backend)
            if frame.empty:
                continue

            frames.append(frame)
            break

    if not frames:
        return pd.DataFrame()

    result = pd.concat(frames, ignore_index=True)
    sort_cols = ["ranks", "kokkos_use", "run"] if "run" in result.columns else ["ranks", "kokkos_use"]
    return result.sort_values(sort_cols).reset_index(drop=True)


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


# Brighter palette (still distinguishable ON vs OFF).
PIPELINE_COLOR = "#1E90FF"
MEMORY_COLOR = "#FF8C1A"
PIPELINE_ERR_COLOR = "#1565C0"
MEMORY_ERR_COLOR = "#E65100"
# Display labels used in compare charts (after mapping from KOKKOS_ON/OFF).
COMPARE_COLORS = {
    "KOKKOS::CUDA": "#1E90FF",
    "KOKKOS::HIP": "#1E90FF",
    "Kokkos::OpenMP": "#1E90FF",
    "KOKKOS::CPU": "#1E90FF",
    "KOKKOS": "#1E90FF",
    "CUDA": "#FF4D6D",
    "HIP": "#FF4D6D",
    "Serial": "#FF4D6D",
    "CPU": "#FF4D6D",
}
COMPARE_HUE_ORDER = (
    "CUDA",
    "HIP",
    "Serial",
    "CPU",
    "KOKKOS::CUDA",
    "KOKKOS::HIP",
    "Kokkos::OpenMP",
    "KOKKOS::CPU",
    "KOKKOS",
)
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
    ax_pipeline.set_xlabel("UPC++ Ranks")
    ax_pipeline.set_ylabel("Runtime(sec)", color=PIPELINE_COLOR)
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


def plot_compare_results(
    data: pd.DataFrame,
    title: str,
    output: Optional[Path],
    show: bool,
) -> None:
    pipeline_col = "Pipeline timing (seconds)"

    if pipeline_col not in data.columns:
        sys.exit(f"Missing column '{pipeline_col}' in aggregated results.")

    if "kokkos_use" not in data.columns:
        sys.exit("Compare chart requires a 'kokkos_use' column in aggregated results.")

    plot_data = data.copy()
    backends = (
        plot_data["backend"].astype(str).str.upper()
        if "backend" in plot_data.columns
        else pd.Series(["NATIVE"] * len(plot_data))
    )
    plot_data["impl"] = [
        display_impl_label(kokkos, backend)
        for kokkos, backend in zip(plot_data["kokkos_use"], backends)
    ]
    present = [label for label in COMPARE_HUE_ORDER if label in set(plot_data["impl"])]
    palette = {label: COMPARE_COLORS[label] for label in present}

    plot_data["rank_label"] = plot_data["ranks"].astype(str)
    use_error_bars = (
        "run" in plot_data.columns
        and plot_data.groupby(["ranks", "impl"])["run"].nunique().max() > 1
    )

    sns.set_theme(style="ticks", context="talk", palette="colorblind")
    fig, ax = plt.subplots(figsize=(10, 6))

    sns.barplot(
        data=plot_data,
        x="rank_label",
        y=pipeline_col,
        hue="impl",
        hue_order=present,
        palette=palette,
        edgecolor="white",
        linewidth=0.8,
        errorbar="sd" if use_error_bars else None,
        capsize=ERRORBAR_CAPSIZE if use_error_bars else 0,
        err_kws={"linewidth": ERRORBAR_LINEWIDTH},
        ax=ax,
    )
    ax.set_xlabel("UPC++ Ranks")
    ax.set_ylabel("Runtime(sec)")
    ax.set_title(title)
    ax.set_axisbelow(True)
    ax.grid(
        axis="y",
        color="#D0D0D0",
        linewidth=0.5,
        linestyle="-",
        zorder=0,
    )
    ax.legend(title=None)
    sns.despine(ax=ax)

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

    if args.compare and args.kokkos_use:
        sys.exit("Use either --compare or --kokkos-use, not both.")

    if args.compare:
        results_scope = root / "results"
        if args.results_group:
            results_scope = results_scope / args.results_group
        data = load_compare_results(root, args.backend, args.results_group)
        if data.empty:
            sys.exit(
                f"No {SUMMARY_CSV_NAME} files found for both KOKKOS_ON and KOKKOS_OFF "
                f"under {results_scope}"
            )
        if "kokkos_use" in data.columns and data["kokkos_use"].nunique() > 1:
            title = "MHM2 Kmer Analysis Proxy"
        else:
            title = build_chart_title(data, backend=args.backend)
    else:
        data = load_results(root, args.batch_dir, args.kokkos_use, args.backend)
        if data.empty:
            sys.exit(
                f"No {SUMMARY_CSV_NAME} files found in KOKKOS_* directories under "
                f"{resolve_batch_dir(root, args.batch_dir)}"
            )
        title = build_chart_title(data, args.kokkos_use, args.backend)

    pipeline_col = "Pipeline timing (seconds)"
    memory_col = "Peak Memory (GB)"
    if args.compare or (
        "kokkos_use" in data.columns and data["kokkos_use"].nunique() > 1
    ):
        if "run" in data.columns and data.groupby(["ranks", "kokkos_use"])["run"].nunique().max() > 1:
            summary = (
                data.groupby(["ranks", "kokkos_use"], as_index=False)
                .agg(
                    **{
                        pipeline_col: (pipeline_col, "mean"),
                        f"{pipeline_col} std": (pipeline_col, "std"),
                        memory_col: (memory_col, "mean"),
                        f"{memory_col} std": (memory_col, "std"),
                        "runs": ("run", "count"),
                    }
                )
                .sort_values(["ranks", "kokkos_use"])
                .reset_index(drop=True)
            )
            print(summary.to_string(index=False))
        else:
            cols = ["kokkos_use", "output_dir", "ranks", pipeline_col, memory_col]
            cols = [col for col in cols if col in data.columns]
            print(data[cols].to_string(index=False))

        plot_compare_results(data, title, args.output, args.show)
    else:
        if "run" in data.columns and data.groupby("ranks")["run"].nunique().max() > 1:
            summary = summarize_by_rank(data, pipeline_col, memory_col)
            print(summary.to_string(index=False))
        else:
            print(data[["output_dir", "ranks", pipeline_col, memory_col]].to_string(index=False))

        plot_results(data, title, args.output, args.show)


if __name__ == "__main__":
    main()
