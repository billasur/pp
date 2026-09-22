"""Verify integrity, distribution, and reproducibility of gold parity fixtures."""

import os
import sys
import json
import math
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.laya_oracle import PatchedRLAgent


def verify_fixtures(fixture_path: str = "fixtures/laya_fixtures.jsonl"):
    if not os.path.exists(fixture_path):
        print(f"Error: Fixture file not found: {fixture_path}")
        sys.exit(1)

    with open(fixture_path, "r", encoding="utf-8") as f:
        records = [json.loads(line) for line in f]

    print(f"Total Fixtures Loaded: {len(records)}")
    assert len(records) >= 300, f"Expected >= 300 fixtures, got {len(records)}"

    bucket_counts = {}
    for r in records:
        b = r["bucket"]
        bucket_counts[b] = bucket_counts.get(b, 0) + 1

        # Check fields
        assert "input_ids" in r and len(r["input_ids"]) > 0
        assert "markers" in r and len(r["markers"]) > 0
        assert "raw_logits" in r and len(r["raw_logits"]) == len(r["markers"])
        assert "probabilities" in r and len(r["probabilities"]) == len(r["markers"])
        assert "confidence" in r and 0.0 <= r["confidence"] <= 1.0

        probs = list(r["probabilities"].values())
        prob_sum = sum(probs)
        assert abs(prob_sum - 1.0) < 1e-3, f"Probabilities do not sum to 1.0: {prob_sum}"

    print("\nBucket Distribution Check:")
    required_buckets = ["choice:2", "choice:3-5", "choice:6-10", "choice:11+", "score:3-5", "noul:2"]
    for b in required_buckets:
        count = bucket_counts.get(b, 0)
        print(f"  - {b:12s}: {count:3d} records")
        assert count >= 20, f"Bucket {b} has insufficient records: {count}"

    print("\nVerifying Reproducibility on Deterministic Sample...")
    agent = PatchedRLAgent(model_id_or_path="convaiinnovations/laya", use_fp16=True)
    sample_indices = [0, 50, 100, 150, 200, 250, 280, 299]
    for idx in sample_indices:
        if idx >= len(records):
            continue
        rec = records[idx]
        res = agent.evaluate_with_details(rec["state"], {rec["qid"]: rec["question"]})
        repro_logits = res["logits"][rec["qid"]]
        orig_logits = rec["raw_logits"]
        diff = max(abs(a - b) for a, b in zip(orig_logits, repro_logits))
        assert diff < 1e-2, f"Fixture {idx} mismatch: max diff = {diff}"
        print(f"  - Fixture #{idx:3d} [{rec['bucket']}]: max logit delta = {diff:.6f} (PASS)")

    print("\n[ALL CHECKS PASSED] Fixtures are valid, well-distributed, and reproducible.")


if __name__ == "__main__":
    verify_fixtures()
