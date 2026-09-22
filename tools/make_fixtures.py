"""Generate N >= 300 gold parity test fixtures using Laya reference oracle."""

import os
import sys
import json
import random
from typing import Dict, Any, List

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.laya_oracle import PatchedRLAgent
from laya.common import temp_bucket, QTYPES


def generate_scenario_library() -> List[Dict[str, Any]]:
    scenarios = []

    apps = ["Safari", "Brave", "Finder", "Terminal", "System Settings", "Notes", "Mail", "Slack", "Messages", "Music", "Preview", "Code", "TextEdit", "Calendar", "Reminders", "Maps"]
    tabs = ["GitHub - pull request #42", "Hacker News", "YouTube - Rick Astley", "Stripe Dashboard", "AWS Console", "macOS Developer Docs", "Figma - UI Design System", "Linear - Sprint Backlog", "Substack Feed", "Google Search"]
    files = ["report.pdf", "invoice_2026.docx", "main.swift", "Package.swift", "schema.sql", "notes.txt", "archive.tar.gz", "photo.png", "dataset.jsonl", "config.yaml"]
    contacts = ["Alice", "Bob", "Charlie", "David", "Emma", "Frank", "Grace", "Hannah", "Ian", "Jack", "Kavita", "Liam", "Maya", "Noah", "Olivia", "Priya"]

    # 1. choice:2 (Binary Choices) - 60 records
    for i in range(60):
        app1, app2 = random.sample(apps, 2)
        scenarios.append({
            "state": f"Frontmost window is {app1}. User said: 'Switch to {app2}'.",
            "qid": f"choice_2_{i}",
            "question": {
                "type": "choice",
                "instructions": f"Which application is the user asking to activate?",
                "criteria": {
                    app1.lower().replace(" ", "_"): f"Stay in {app1}",
                    app2.lower().replace(" ", "_"): f"Bring {app2} to the front",
                }
            }
        })

    # 2. choice:3-5 (3-5 options) - 80 records
    kinds = ["open_url", "click", "type_text", "press_key", "menu"]
    for i in range(80):
        k = random.choice([3, 4, 5])
        selected_apps = random.sample(apps, k)
        target = selected_apps[0]
        crit = {app.lower().replace(" ", "_"): f"Launch or switch to {app}" for app in selected_apps}
        scenarios.append({
            "state": f"Active apps: {', '.join(selected_apps)}. Command: 'Open {target}'.",
            "qid": f"choice_3_5_{i}",
            "question": {
                "type": "choice",
                "instructions": "Which application matches the command?",
                "criteria": crit
            }
        })

    # 3. choice:6-10 (6-10 options) - 80 records
    operations = {
        "CLICK": "Press or click on an on-screen button or link",
        "TYPE_TEXT": "Type words into an active text input",
        "OPEN_APP": "Launch or activate an installed application",
        "OPEN_URL": "Open a website address in the default browser",
        "OPEN_FOLDER": "Open a directory or folder in Finder",
        "MENU": "Choose an item from the application menu bar",
        "QUIT_APP": "Terminate or close the application",
        "WAIT": "Wait for page or controls to load",
        "DONE": "The command has been completely fulfilled",
        "BLOCKED": "No offered action can make progress"
    }
    for i in range(80):
        k = random.choice([6, 7, 8, 9, 10])
        op_keys = random.sample(list(operations.keys()), k)
        if "CLICK" not in op_keys and i % 2 == 0:
            op_keys[0] = "CLICK"
        crit = {k: operations[k] for k in op_keys}
        scenarios.append({
            "state": f"On screen: 12 buttons, 3 text fields in Safari. Spoken command: 'Click the submit button'.",
            "qid": f"choice_6_10_{i}",
            "question": {
                "type": "choice",
                "instructions": "Choose the next operation toward fulfilling the goal.",
                "criteria": crit
            }
        })

    # 4. choice:11+ (11 to 24 options) - 100 records (critical for choice:11+ temp=0.1006)
    for i in range(100):
        k = random.choice([12, 14, 16, 18, 20, 24])
        selected_elements = [f"element_{idx}" for idx in range(k)]
        target_idx = random.randint(0, k - 1)
        crit = {}
        for idx in range(k):
            name = f"Button_{idx}" if idx != target_idx else "Save_Document_Button"
            crit[f"ctrl_{idx}"] = f"Control [{idx}] {name} on screen"
        scenarios.append({
            "state": f"Window: TextEdit - Untitled. Controls: {k} items displayed. User goal: 'Save Document'.",
            "qid": f"choice_11_plus_{i}",
            "question": {
                "type": "choice",
                "instructions": "Which control on screen should be pressed to save the document?",
                "criteria": crit
            }
        })

    # 5. score:3-5 (Quality / Urgency / Progress) - 30 records
    for i in range(30):
        levels = [
            "Level 0: Not related or irrelevant",
            "Level 1: Partially related to task",
            "Level 2: Strongly aligned with intent",
            "Level 3: Exact perfect match",
        ]
        scenarios.append({
            "state": f"Evaluating candidate action 'Click Close' for goal 'Close the active window'.",
            "qid": f"score_{i}",
            "question": {
                "type": "score",
                "instructions": "How well does the candidate action fulfill the user goal?",
                "criteria": levels
            }
        })

    # 6. noul:2 (Yes/No judgments: Safety, Finishes, Already Done) - 60 records
    for i in range(60):
        is_done = (i % 2 == 0)
        action_desc = "rm -rf ~/Documents" if i % 3 == 0 else "curl https://example.com"
        scenarios.append({
            "state": f"Proposed shell command execution: `{action_desc}`.",
            "qid": f"noul_{i}",
            "question": {
                "type": "noul",
                "instructions": "Is this action dangerous, destructive, or requiring user confirmation?",
                "criteria": {
                    "false": "Safe non-destructive read or regular desktop action.",
                    "true": "Destructive delete, outward transmission, or security setting modification."
                }
            }
        })

    return scenarios


def main():
    print("=== Laya Parity Fixture Generator ===")
    os.makedirs("fixtures", exist_ok=True)
    fixture_path = "fixtures/laya_fixtures.jsonl"

    print("Loading Laya Reference Oracle (MPS/CPU)...")
    agent = PatchedRLAgent(model_id_or_path="convaiinnovations/laya", use_fp16=True)

    scenarios = generate_scenario_library()
    print(f"Generated {len(scenarios)} candidate scenarios.")

    records = []
    bucket_counts = {}

    for idx, item in enumerate(scenarios):
        state = item["state"]
        qid = item["qid"]
        q = item["question"]

        res = agent.evaluate_with_details(state, {qid: q})
        ans = res["answers"][qid]
        logits = res["logits"][qid]
        seq = res["sequences"][qid]

        qtype_num = QTYPES[q["type"]]
        k = len(seq["markers"])
        bucket = temp_bucket(qtype_num, k)
        bucket_counts[bucket] = bucket_counts.get(bucket, 0) + 1

        rec = {
            "index": idx,
            "qid": qid,
            "bucket": bucket,
            "qtype": q["type"],
            "state": state,
            "question": q,
            "input_ids": seq["ids"],
            "markers": seq["markers"],
            "options": seq["options"],
            "raw_logits": logits,
            "t_scale": ans["t_scale"],
            "probabilities": ans["probabilities"] if "probabilities" in ans else {"false": 1.0 - ans["noul"], "true": ans["noul"]},
            "confidence": ans["confidence"],
            "expected_choice": ans.get("choice") or (ans.get("score") if q["type"] == "score" else ans.get("noul")),
        }
        records.append(rec)

        if (idx + 1) % 50 == 0 or idx == len(scenarios) - 1:
            print(f"Processed {idx + 1}/{len(scenarios)} fixtures...")

    with open(fixture_path, "w", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(rec) + "\n")

    print(f"\n[DONE] Wrote {len(records)} fixtures to {fixture_path}")
    print("Bucket Distribution:")
    for b, count in sorted(bucket_counts.items()):
        print(f"  - {b:12s}: {count:3d} records")


if __name__ == "__main__":
    main()
