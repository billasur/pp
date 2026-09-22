#!/usr/bin/env python3
"""Convert Laya PyTorch checkpoint to MLX-compatible safetensors and package manifest.

Extracts ModernBERT-large encoder and 2-layer typed decision head,
normalizes tensor keys, casts to fp16 (or fp32), copies tokenizer assets,
and generates a versioned package manifest with SHA256 checksums.
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Dict, Any

import torch
import safetensors.torch
from huggingface_hub import snapshot_download


def compute_sha256(filepath: Path) -> str:
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def convert_laya(
    model_id_or_path: str = "convaiinnovations/laya",
    output_dir: str = "models/laya-mlx",
    dtype: str = "float16",
    strip_act_head: bool = False,
):
    out_path = Path(output_dir)
    out_path.mkdir(parents=True, exist_ok=True)

    print(f"=== Converting Laya Checkpoint ===")
    print(f"Source: {model_id_or_path}")
    print(f"Destination: {out_path}")
    print(f"Target precision: {dtype}")

    # 1. Locate checkpoint files
    if os.path.isdir(model_id_or_path):
        source_dir = Path(model_id_or_path)
    else:
        print(f"Downloading/resolving Hugging Face snapshot for {model_id_or_path}...")
        source_dir = Path(
            snapshot_download(
                model_id_or_path,
                allow_patterns=[
                    "rl_agent_config.json",
                    "model.safetensors",
                    "tokenizer/*",
                    "encoder/*",
                ],
            )
        )

    # 2. Read configs
    rl_cfg_file = source_dir / "rl_agent_config.json"
    with open(rl_cfg_file) as f:
        rl_cfg = json.load(f)

    enc_cfg_file = source_dir / "encoder" / "config.json"
    with open(enc_cfg_file) as f:
        enc_cfg = json.load(f)

    # 3. Load raw safetensors
    weights_file = source_dir / "model.safetensors"
    print(f"Loading raw weights from {weights_file}...")
    raw_weights = safetensors.torch.load_file(str(weights_file))
    print(f"Loaded {len(raw_weights)} tensors.")

    # Target dtype
    torch_dtype = torch.float16 if dtype == "float16" else torch.float32

    # 4. Transform and map tensor keys
    # Keys will be structured for direct loading into Swift MLX modules:
    #   embeddings.tok_embeddings.weight
    #   embeddings.norm.weight
    #   layers.{i}.attn_norm.weight (i > 0)
    #   layers.{i}.attn.Wqkv.weight
    #   layers.{i}.attn.Wo.weight
    #   layers.{i}.mlp_norm.weight
    #   layers.{i}.mlp.Wi.weight
    #   layers.{i}.mlp.Wo.weight
    #   final_norm.weight
    #   type_emb.weight
    #   head.layers.{i}.*
    #   scorer.0.* (LayerNorm)
    #   scorer.1.* (Linear)
    #   scorer.3.* (Linear)
    converted: Dict[str, torch.Tensor] = {}

    for name, tensor in raw_weights.items():
        if strip_act_head and name.startswith("act_head."):
            continue

        target_name = name
        if target_name.startswith("encoder."):
            # Strip 'encoder.' prefix for clean module hierarchy
            target_name = target_name[len("encoder."):]

        # Convert to target precision (all weights fp16/fp32)
        converted[target_name] = tensor.to(torch_dtype).contiguous()

    print(f"Converted {len(converted)} tensors to {dtype}.")

    # 5. Save converted safetensors
    out_weights = out_path / "model.safetensors"
    print(f"Writing {out_weights}...")
    safetensors.torch.save_file(converted, str(out_weights))

    # 6. Copy tokenizer assets
    tok_dir = source_dir / "tokenizer"
    tok_out_dir = out_path / "tokenizer"
    tok_out_dir.mkdir(parents=True, exist_ok=True)
    for tok_file in ["tokenizer.json", "tokenizer_config.json"]:
        src_f = tok_dir / tok_file
        if src_f.exists():
            shutil.copy2(src_f, tok_out_dir / tok_file)
            # Also keep a copy in root of package for easy loading
            shutil.copy2(src_f, out_path / tok_file)
            print(f"Copied {tok_file} to package.")

    # 7. Write consolidated config.json
    unified_cfg = {
        "model_id": "convaiinnovations/laya",
        "architecture": "modernbert_laya",
        "precision": dtype,
        "vocab_size": enc_cfg.get("vocab_size", 50368),
        "hidden_size": enc_cfg.get("hidden_size", 1024),
        "intermediate_size": enc_cfg.get("intermediate_size", 2624),
        "num_hidden_layers": enc_cfg.get("num_hidden_layers", 28),
        "num_attention_heads": enc_cfg.get("num_attention_heads", 16),
        "head_dim": enc_cfg.get("hidden_size", 1024) // enc_cfg.get("num_attention_heads", 16),
        "norm_eps": enc_cfg.get("norm_eps", 1e-05),
        "norm_bias": enc_cfg.get("norm_bias", False),
        "attention_bias": enc_cfg.get("attention_bias", False),
        "mlp_bias": enc_cfg.get("mlp_bias", False),
        "max_position_embeddings": enc_cfg.get("max_position_embeddings", 8192),
        "local_attention": enc_cfg.get("local_attention", 128),
        "sliding_window": enc_cfg.get("local_attention", 128) // 2,
        "global_attn_every_n_layers": enc_cfg.get("global_attn_every_n_layers", 3),
        "rope_theta_full": enc_cfg.get("rope_parameters", {}).get("full_attention", {}).get("rope_theta", 160000.0),
        "rope_theta_sliding": enc_cfg.get("rope_parameters", {}).get("sliding_attention", {}).get("rope_theta", 10000.0),
        "layer_types": enc_cfg.get("layer_types", []),
        "head_layers": rl_cfg.get("head_layers", 2),
        "head_d_model": enc_cfg.get("hidden_size", 1024),
        "head_nhead": max(1, enc_cfg.get("hidden_size", 1024) // 64),
        "head_dim_feedforward": 4 * enc_cfg.get("hidden_size", 1024),
        "head_activation": "relu",
        "max_len": rl_cfg.get("max_len", 512),
        "head_max_len": rl_cfg.get("head_max_len", 192),
        "special_tokens": {
            "cls_token_id": 50281,
            "sep_token_id": 50282,
            "pad_token_id": 50283,
            "mask_token_id": 50284,
        },
        "temperature_by_options": rl_cfg.get("temperature_by_options", {
            "choice:2": 1.9063563346862793,
            "choice:3-5": 1.7601518630981445,
            "choice:6-10": 1.0000158548355103,
            "choice:11+": 0.10058280825614929,
            "noul:2": 1.983399510383606,
            "score:3-5": 1.2514300346374512,
        }),
        "default_temperature": rl_cfg.get("temperature", [
            1.6369030475616455,
            1.2514300346374512,
            1.983399510383606,
        ]),
    }

    out_cfg = out_path / "config.json"
    with open(out_cfg, "w") as f:
        json.dump(unified_cfg, f, indent=2)
    print(f"Wrote unified config to {out_cfg}.")

    # 8. Generate manifest.json with SHA256 checksums
    files_to_hash = [
        "model.safetensors",
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
    ]
    file_manifest = {}
    for fname in files_to_hash:
        fpath = out_path / fname
        if fpath.exists():
            file_manifest[fname] = {
                "size_bytes": fpath.stat().st_size,
                "sha256": compute_sha256(fpath),
            }

    manifest = {
        "manifest_version": "1.0.0",
        "model_id": "convaiinnovations/laya",
        "package_name": "laya-421m-mlx",
        "precision": dtype,
        "format": "safetensors",
        "min_pp_version": "1.0.0",
        "files": file_manifest,
    }

    manifest_file = out_path / "manifest.json"
    with open(manifest_file, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"Wrote package manifest to {manifest_file}.")
    print("=== Conversion Complete ===")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert Laya weights for Swift MLX")
    parser.add_argument("--model-id", default="convaiinnovations/laya", help="Hugging Face model ID or path")
    parser.add_argument("--output-dir", default="models/laya-mlx", help="Output directory")
    parser.add_argument("--dtype", choices=["float16", "float32"], default="float16", help="Target precision")
    parser.add_argument("--strip-act-head", action="store_true", help="Strip unused act_head weights")
    args = parser.parse_args()

    convert_laya(
        model_id_or_path=args.model_id,
        output_dir=args.output_dir,
        dtype=args.dtype,
        strip_act_head=args.strip_act_head,
    )
