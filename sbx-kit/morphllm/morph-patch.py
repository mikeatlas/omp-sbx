#!/usr/bin/env python3
"""
Patches the installed pi-morphllm-plugin for use under omp-sbx.

Usage: morph-patch.py <config.js path> <index.js path>

Applies one change:
  1. index.js: suppresses the "MorphLLM (N key)" footer status in the omp UI.

Routing and fallback patches previously applied here were removed in favour of
@morphllm/morphsdk 0.2.191, which routes /api/code-search/* through
api.morphllm.com and sends the API key natively.
"""
from pathlib import Path
import sys


def apply_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"{label} patch anchor not found")
    return text.replace(old, new, 1)


index_path = Path(sys.argv[2])

index_text = index_path.read_text()
index_text = apply_once(
    index_text,
    'ctx.ui.setStatus("morph", formatMorphFooterStatus(config));',
    'ctx.ui.setStatus("morph", undefined);',
    "index.js footer status",
)
index_path.write_text(index_text)
