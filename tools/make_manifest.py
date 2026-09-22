#!/usr/bin/env python3
"""Build a publishable model-package manifest for a converted MLX Laya package.

The manifest is the contract between the app and any model package. It records what
the weights are, what they must be loaded by, and the checksums needed to activate
them atomically. `tools/convert_laya.py` calls this after conversion; it can also be
run standalone to refresh a manifest for a package that was converted earlier.

Usage:
    python3 Tools/make_manifest.py models/laya-mlx
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

# Files that must be present in every package, and are therefore always hashed.
CORE_FILES = ["model.safetensors", "config.json", "tokenizer.json", "tokenizer_config.json"]

SPECIAL_TOKEN_NAMES = {
    "cls": "[CLS]",
    "sep": "[SEP]",
    "pad": "[PAD]",
    "mask": "[MASK]",
    "unk": "[UNK]",
}

REQUIRED_HEADS = ["choice", "score", "noul"]

# The product name of the standard pp package. Directory names are not a contract.
DEFAULT_PACKAGE_NAME = "laya-421m-mlx"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def special_tokens(tokenizer_path: Path) -> dict:
    """Read the real special-token ids out of tokenizer.json.

    Guessing these is how a "compatible" checkpoint silently produces garbage, so the
    manifest carries the ids the tokenizer actually defines.
    """
    data = json.loads(tokenizer_path.read_text())
    by_content = {token["content"]: token["id"] for token in data.get("added_tokens", [])}
    ids = {}
    for key, content in SPECIAL_TOKEN_NAMES.items():
        if content in by_content:
            ids[key] = by_content[content]
    ids["mask_token"] = SPECIAL_TOKEN_NAMES["mask"]
    return ids


def build(package_dir: Path, package_name: str = DEFAULT_PACKAGE_NAME) -> dict:
    config_path = package_dir / "config.json"
    tokenizer_path = package_dir / "tokenizer.json"
    for required in (config_path, tokenizer_path):
        if not required.exists():
            raise SystemExit(f"missing {required} in {package_dir}")

    config = json.loads(config_path.read_text())
    files = {}
    for name in CORE_FILES:
        candidate = package_dir / name
        if not candidate.exists():
            continue
        files[name] = {"size_bytes": candidate.stat().st_size, "sha256": sha256(candidate)}

    return {
        "manifest_version": "2.0.0",
        "model_id": config.get("model_id", "convaiinnovations/laya"),
        "package_name": config.get("package_name", package_name),
        "architecture": config.get("architecture", "modernbert_laya"),
        "precision": config.get("precision", "float16"),
        "format": "safetensors",
        "min_pp_version": "0.1.0",
        "max_position_embeddings": config.get("max_position_embeddings", 8192),
        "hidden_size": config.get("hidden_size", 1024),
        "num_hidden_layers": config.get("num_hidden_layers", 28),
        "special_tokens": special_tokens(tokenizer_path),
        "heads": REQUIRED_HEADS,
        "files": files,
    }


def main(argv: list[str]) -> int:
    package_dir = Path(argv[1] if len(argv) > 1 else "models/laya-mlx")
    manifest = build(package_dir)
    target = package_dir / "manifest.json"
    target.write_text(json.dumps(manifest, indent=2) + "\n")
    total = sum(entry["size_bytes"] for entry in manifest["files"].values())
    print(f"wrote {target} ({len(manifest['files'])} files, {total / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
