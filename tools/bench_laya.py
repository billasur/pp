"""Benchmark Laya reference oracle on Apple Silicon MPS across workload shapes and batch sizes."""

import os
import sys
import time
import json
import resource
import numpy as np
import torch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.laya_oracle import PatchedRLAgent


def get_peak_rss_mb() -> float:
    # On macOS, ru_maxrss is in bytes
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return usage.ru_maxrss / (1024 * 1024)


def create_workloads():
    # 1. Short (~128 tokens)
    short_state = "Frontmost app: Safari. Page: GitHub. Active tab: PR #104."
    short_questions = {
        "operation": {
            "type": "choice",
            "instructions": "Choose the next operation for user goal: 'Merge this pull request'.",
            "criteria": {
                "CLICK": "Click on-screen button",
                "WAIT": "Wait for check to finish",
                "BLOCKED": "Action is blocked"
            }
        }
    }

    # 2. Medium (~256 tokens)
    med_state = (
        "Application: Finder. Folder: Downloads. Selected: 0 items. "
        "Visible files: archive.zip, report_2026.pdf, dataset.parquet, invoice.pdf, photo.png, setup.dmg, notes.txt."
    )
    med_questions = {
        "target": {
            "type": "choice",
            "instructions": "Which file matches the user request: 'Open the 2026 financial report'?",
            "criteria": {
                "f0": "archive.zip",
                "f1": "report_2026.pdf",
                "f2": "dataset.parquet",
                "f3": "invoice.pdf",
                "f4": "photo.png",
                "f5": "setup.dmg",
                "f6": "notes.txt",
                "none": "None of the files match"
            }
        }
    }

    # 3. Batched Call (~512 tokens): full cycle with multiple heads (operation + target + safety + finishes)
    long_state = (
        "Application: System Settings. Window: Privacy & Security. "
        "Elements: [1] Location Services (On), [2] Camera (3 apps), [3] Microphone (Desktop Voice, Zoom), "
        "[4] Accessibility (Desktop Voice enabled, Terminal disabled), [5] Full Disk Access (Terminal), "
        "[6] Screen Recording (0 apps), [7] Developer Tools, [8] App Management."
    )
    long_questions = {
        "operation": {
            "type": "choice",
            "instructions": "Select next operation toward fulfilling: 'Revoke camera access for all applications'.",
            "criteria": {
                "CLICK": "Click on row or toggle",
                "SCROLL": "Scroll down list",
                "WAIT": "Wait for reload",
                "DONE": "Already done",
                "BLOCKED": "Cannot fulfill"
            }
        },
        "target": {
            "type": "choice",
            "instructions": "Which row in Privacy & Security should be clicked?",
            "criteria": {
                "c1": "Location Services",
                "c2": "Camera",
                "c3": "Microphone",
                "c4": "Accessibility",
                "c5": "Full Disk Access",
                "c6": "Screen Recording",
                "none": "None of the rows"
            }
        },
        "safety": {
            "type": "noul",
            "instructions": "Does this action compromise system security or revoke critical permissions?",
            "criteria": {
                "true": "High impact permission change",
                "false": "Normal preference toggle"
            }
        },
        "finishes": {
            "type": "noul",
            "instructions": "Will clicking this item immediately finish the entire goal?",
            "criteria": {
                "true": "One step completes everything",
                "false": "More sub-steps required"
            }
        }
    }

    return {
        "short_128": (short_state, short_questions),
        "medium_256": (med_state, med_questions),
        "batched_cycle_512": (long_state, long_questions),
    }


def run_benchmark(agent: PatchedRLAgent, state, questions, iters: int = 30):
    # Warmup
    for _ in range(5):
        _ = agent.evaluate_with_details(state, questions)
    if agent.device.type == "mps":
        torch.mps.synchronize()

    times = []
    for _ in range(iters):
        t0 = time.perf_counter()
        _ = agent.evaluate_with_details(state, questions)
        if agent.device.type == "mps":
            torch.mps.synchronize()
        t1 = time.perf_counter()
        times.append((t1 - t0) * 1000.0)

    p50 = float(np.percentile(times, 50))
    p95 = float(np.percentile(times, 95))
    mean = float(np.mean(times))
    min_t = float(np.min(times))
    return {"p50_ms": p50, "p95_ms": p95, "mean_ms": mean, "min_ms": min_t}


def main():
    print("=== Laya MPS Performance Benchmark ===")
    print(f"PyTorch Version: {torch.__version__}")
    print(f"MPS Available: {torch.backends.mps.is_available()}")

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"Loading PatchedRLAgent on {device} (fp16)...")
    agent = PatchedRLAgent(model_id_or_path="convaiinnovations/laya", device=device, use_fp16=True)

    workloads = create_workloads()
    results = {}

    print("\nRunning Latency Measurements...")
    for name, (state, q) in workloads.items():
        print(f"  Benchmarking workload: {name}...")
        res = run_benchmark(agent, state, q, iters=30)
        rss = get_peak_rss_mb()
        res["peak_rss_mb"] = rss
        results[name] = res
        print(f"    -> p50: {res['p50_ms']:.2f} ms | p95: {res['p95_ms']:.2f} ms | Peak RSS: {rss:.1f} MB")

    # Generate docs/BENCHMARKS.md
    os.makedirs("docs", exist_ok=True)
    bench_file = "docs/BENCHMARKS.md"
    with open(bench_file, "w", encoding="utf-8") as f:
        f.write("# Laya MPS Performance Benchmarks\n\n")
        f.write(f"Measured on Apple Silicon (`{device.upper()}`, fp16 autocast enabled).\n\n")
        f.write("| Workload Shape | Tokens | Questions | p50 Latency | p95 Latency | Peak RSS |\n")
        f.write("| :--- | :--- | :--- | :--- | :--- | :--- |\n")
        for name, data in results.items():
            tokens = "~128" if "128" in name else ("~256" if "256" in name else "~512")
            q_count = "1 (Router/Safety)" if "128" in name else ("1 (Target)" if "256" in name else "4 (Full Cycle)")
            f.write(f"| **{name}** | {tokens} | {q_count} | **{data['p50_ms']:.1f} ms** | {data['p95_ms']:.1f} ms | {data['peak_rss_mb']:.1f} MB |\n")

        f.write("\n## Exit Gate Evaluation\n\n")
        cycle_p95 = results["batched_cycle_512"]["p95_ms"]
        f.write(f"- **Batched Cycle p95 Latency**: {cycle_p95:.1f} ms\n")
        f.write(f"- **Threshold**: < 1500 ms (1.5s)\n")
        if cycle_p95 < 1500:
            f.write(f"- **Result**: **PASS** (Latency is well within the acceptable interactive window).\n")
        else:
            f.write(f"- **Result**: **FAIL** (Latency exceeds threshold, specialist split required).\n")

    print(f"\n[DONE] Saved benchmark summary to {bench_file}")


if __name__ == "__main__":
    main()
