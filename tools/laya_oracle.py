"""Laya Reference Oracle with Apple Silicon MPS autocast support."""

import os
import json
import time
import numpy as np
import torch
from typing import Dict, Any, Union, List, Optional
import laya
from laya.agent import RLAgent
from laya.common import (
    QTYPES,
    render_options,
    build_sequence,
    collate_items,
    temp_bucket,
    confidence_from_probs,
)


class PatchedRLAgent(RLAgent):
    """Subclass of RLAgent that supports fp16 and autocast on Apple Silicon MPS."""

    def __init__(
        self,
        model_id_or_path: str = "convaiinnovations/laya",
        device: str = "mps" if (hasattr(torch.backends, "mps") and torch.backends.mps.is_available()) else "cpu",
        use_fp16: bool = True,
        token: Optional[str] = None,
        subfolder: Optional[str] = None,
    ):
        super().__init__(model_id_or_path=model_id_or_path, device=device, token=token, subfolder=subfolder)

        # Preserve exact checkpoint temperatures (e.g. choice:11+ = 0.1006) for parity fidelity
        self.temperature_by_options = {k: float(v) for k, v in self.temperature_by_options_raw.items()}
        self.temperature = [float(v) for v in self.temperature_raw]

        # On Apple Silicon MPS, fp16 is supported and drastically accelerates compute
        if self.device.type == "mps" and use_fp16:
            self.dtype = torch.float16
            self.model.to(self.device, dtype=self.dtype).eval()
        elif self.device.type == "cuda" and use_fp16:
            self.dtype = torch.float16
            self.model.to(self.device, dtype=self.dtype).eval()

    @torch.no_grad()
    def evaluate_with_details(
        self, state: Union[str, dict, list], questions: Dict[str, Dict[str, Any]]
    ) -> Dict[str, Any]:
        """Evaluate questions and return raw logits, token ids, markers, and calibrated answers."""
        ids = list(questions.keys())
        items = []
        max_len = self.cfg.get("max_len", 512)
        head_max_len = self.cfg.get("head_max_len", 192)

        sequence_details = {}
        for qid in ids:
            q = self._to_internal(questions[qid])
            seq, markers = build_sequence(self.tok, state, q, max_len, head_max_len)
            if len(markers) != len(render_options(q)):
                raise ValueError("question %r options exceed head_max_len=%d" % (qid, head_max_len))
            items.append({"ids": seq, "markers": markers, "qtype": QTYPES[q["t"]]})
            sequence_details[qid] = {
                "ids": [int(x) for x in seq],
                "markers": [int(x) for x in markers],
                "options": render_options(q),
            }

        b = collate_items([items], self.tok.pad_token_id)
        use_amp = self.device.type in ("cuda", "mps") and self.dtype == torch.float16

        if use_amp and self.device.type == "mps":
            with torch.autocast(device_type="mps", dtype=torch.float16):
                logits, act = self.model(
                    b["input_ids"].to(self.device),
                    b["attention_mask"].to(self.device),
                    b["marker_pos"].to(self.device),
                    b["marker_mask"].to(self.device),
                    b["qtype"].to(self.device),
                )
        elif use_amp and self.device.type == "cuda":
            with torch.autocast(device_type="cuda", dtype=torch.float16):
                logits, act = self.model(
                    b["input_ids"].to(self.device),
                    b["attention_mask"].to(self.device),
                    b["marker_pos"].to(self.device),
                    b["marker_mask"].to(self.device),
                    b["qtype"].to(self.device),
                )
        else:
            logits, act = self.model(
                b["input_ids"].to(self.device),
                b["attention_mask"].to(self.device),
                b["marker_pos"].to(self.device),
                b["marker_mask"].to(self.device),
                b["qtype"].to(self.device),
            )

        logits = logits.float().cpu().numpy()
        act = torch.softmax(act.float(), -1).cpu().numpy()

        answers = {}
        per_question_logits = {}

        for r, qid in enumerate(ids):
            q = self._to_internal(questions[qid])
            k = len(items[r]["markers"])
            raw_k = logits[r, :k].tolist()
            per_question_logits[qid] = [float(v) for v in raw_k]

            qt = QTYPES[q["t"]]
            t_scale = self.temperature_by_options.get(temp_bucket(qt, k), self.temperature[qt])
            z = logits[r, :k] / t_scale
            p = np.exp(z - z.max())
            p = p / p.sum()

            conf_score = round(confidence_from_probs(p, k), 4)

            if q["t"] == "choice":
                keys = list(q["crit"].keys())
                answers[qid] = {
                    "type": "choice",
                    "choice": keys[int(p.argmax())],
                    "probabilities": {kk: float(v) for kk, v in zip(keys, p)},
                    "confidence": conf_score,
                    "t_scale": float(t_scale),
                }
            elif q["t"] == "score":
                exp_score = float((np.arange(k) * p).sum())
                answers[qid] = {
                    "type": "score",
                    "score": float(exp_score),
                    "legend": {str(i): c for i, c in enumerate(q["crit"])},
                    "probabilities": {str(i): float(v) for i, v in enumerate(p)},
                    "confidence": conf_score,
                    "t_scale": float(t_scale),
                }
            else:
                answers[qid] = {
                    "type": "noul",
                    "noul": float(p[1]),
                    "confidence": float(max(p[1], 1.0 - p[1])),
                    "t_scale": float(t_scale),
                }

        return {
            "answers": answers,
            "logits": per_question_logits,
            "sequences": sequence_details,
            "token_count": int(b["attention_mask"].sum()),
        }
