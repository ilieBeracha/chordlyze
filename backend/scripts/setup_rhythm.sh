#!/usr/bin/env bash
set -euo pipefail
rhythm_backend=$(cd "$(dirname "$0")/.." && pwd)
rhythm_root=${1:-${CHORDLYZE_RHYTHM_DIR:-$rhythm_backend}}
rhythm_python=${PYTHON:-python3.11}
mkdir -p "$rhythm_root"
"$rhythm_python" -m venv "$rhythm_root/.venv-rhythm"
# CPU wheels avoid downloading CUDA runtimes on Linux servers.
if [[ "$(uname -s)" == Linux ]]; then
    "$rhythm_root/.venv-rhythm/bin/python" -m pip install --extra-index-url https://download.pytorch.org/whl/cpu -r "$rhythm_backend/requirements-rhythm.txt"
else
    "$rhythm_root/.venv-rhythm/bin/python" -m pip install -r "$rhythm_backend/requirements-rhythm.txt"
fi
CHORDLYZE_RHYTHM_DIR="$rhythm_root" PYTHONPATH="$rhythm_backend" "$rhythm_root/.venv-rhythm/bin/python" - <<'PY'
import hashlib
from pathlib import Path
import urllib.request
from chordlyze_backend.analysis.rhythm import CHECKPOINT_SHA256, checkpoint_path
path = checkpoint_path()
path.parent.mkdir(parents=True, exist_ok=True)
if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != CHECKPOINT_SHA256:
    pending = path.with_suffix('.download')
    try:
        with urllib.request.urlopen('https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt', timeout=120) as response, pending.open('wb') as out:
            total = 0
            while chunk := response.read(1024*1024):
                total += len(chunk)
                if total > 100*1024*1024: raise RuntimeError('checkpoint exceeded size limit')
                out.write(chunk)
        if hashlib.sha256(pending.read_bytes()).hexdigest() != CHECKPOINT_SHA256:
            raise RuntimeError('rhythm checkpoint hash mismatch')
        pending.replace(path)
    finally:
        pending.unlink(missing_ok=True)
print('Verified Beat This final0 checkpoint')
PY
CHORDLYZE_RHYTHM_DIR="$rhythm_root" PYTHONPATH="$rhythm_backend" "$rhythm_root/.venv-rhythm/bin/python" -m chordlyze_backend.analysis.rhythm_worker --check
