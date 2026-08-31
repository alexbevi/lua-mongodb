"""Read shared provenance from generated conformance artifacts."""

from __future__ import annotations

import json
from pathlib import Path
import re


def specifications_commit(path: Path) -> str:
  value = json.loads(path.read_text(encoding="utf-8")).get("specifications_commit")
  if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
    raise ValueError(f"{path} has no valid specifications commit")
  return value
