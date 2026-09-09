#!/usr/bin/env bash
# Sync versions.yaml images: → *_IMAGE= lines in .env and .env.example.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSIONS_FILE="${ROOT_DIR}/versions.yaml"
TARGETS=("${ROOT_DIR}/.env.example")
if [[ -f "${ROOT_DIR}/.env" ]]; then
  TARGETS+=("${ROOT_DIR}/.env")
fi

# Map versions.yaml image keys → Compose / .env variable names.
# Force UTF-8 stdout: on Windows the default cp1252 console encoding cannot encode
# the arrow in this script's own progress output, which aborted the sync midway.
PYTHONIOENCODING=utf-8 python3 - "$VERSIONS_FILE" "${TARGETS[@]}" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

versions_path = Path(sys.argv[1])
targets = [Path(p) for p in sys.argv[2:]]

KEY_TO_ENV = {
    "staff_portal_ui": "STAFF_PORTAL_UI_IMAGE",
    "registry_staff_portal_ui": "REGISTRY_STAFF_PORTAL_UI_IMAGE",
    "iam_staff_portal_api": "IAM_STAFF_PORTAL_API_IMAGE",
    "master_data_api": "MASTER_DATA_API_IMAGE",
    "awe_api": "AWE_API_IMAGE",
    "awe_ui": "AWE_UI_IMAGE",
    "farmer_registry_staff_api": "FARMER_REGISTRY_STAFF_API_IMAGE",
    "farmer_registry_partner_api": "FARMER_REGISTRY_PARTNER_API_IMAGE",
    "farmer_registry_celery": "FARMER_REGISTRY_CELERY_IMAGE",
    "farmer_registry_db_seed": "FARMER_REGISTRY_DB_SEED_IMAGE",
    "nsr_staff_api": "NSR_REGISTRY_STAFF_API_IMAGE",
    "nsr_partner_api": "NSR_REGISTRY_PARTNER_API_IMAGE",
    "nsr_celery": "NSR_REGISTRY_CELERY_IMAGE",
    "nsr_db_seed": "NSR_REGISTRY_DB_SEED_IMAGE",
    "id_generator": "ID_GENERATOR_IMAGE",
    "pbms": "PBMS_IMAGE",
}

try:
    import yaml  # type: ignore
except ImportError:
    yaml = None

text = versions_path.read_text(encoding="utf-8")
images: dict[str, str] = {}

if yaml is not None:
    data = yaml.safe_load(text) or {}
    images = dict((data.get("images") or {}))
else:
    in_images = False
    for line in text.splitlines():
        if re.match(r"^images:\s*$", line):
            in_images = True
            continue
        if in_images:
            if re.match(r"^[A-Za-z0-9_]+:\s*$", line) and not line.startswith(" "):
                break
            m = re.match(r"^\s+([A-Za-z0-9_]+):\s*(.+?)\s*$", line)
            if m:
                images[m.group(1)] = m.group(2).strip().strip("'\"")

pairs: list[tuple[str, str]] = []
for key, env_name in KEY_TO_ENV.items():
    if key in images:
        pairs.append((env_name, str(images[key])))

if not pairs:
    print(f"No image pins found in {versions_path}", file=sys.stderr)
    sys.exit(1)

marker_begin = "# BEGIN IMAGE PINS (managed by make sync-images)"
marker_end = "# END IMAGE PINS"

block_lines = [marker_begin, "# Sourced from versions.yaml — do not hand-edit; run: make sync-images"]
for env_name, image in pairs:
    block_lines.append(f"{env_name}={image}")
block_lines.append(marker_end)
block = "\n".join(block_lines) + "\n"

block_re = re.compile(
    re.escape(marker_begin) + r".*?" + re.escape(marker_end) + r"\n?",
    re.DOTALL,
)

for target in targets:
    original = target.read_text(encoding="utf-8") if target.exists() else ""
    # Drop any legacy loose IMAGE lines that we now manage in the block.
    managed = {name for name, _ in pairs}
    kept: list[str] = []
    for line in original.splitlines(keepends=True):
        m = re.match(r"^([A-Za-z0-9_]+)=", line)
        if m and m.group(1) in managed:
            continue
        if marker_begin in line or marker_end in line:
            continue
        kept.append(line)
    body = "".join(kept)
    body = block_re.sub("", body).rstrip() + "\n\n" + block
    # newline="" keeps LF endings: Python would otherwise translate to CRLF on Windows,
    # which breaks env parsing and any script sourced by sh inside a container.
    with target.open("w", encoding="utf-8", newline="") as fh:
        fh.write(body)
    print(f"Synced {len(pairs)} image pins → {target}")
PY
