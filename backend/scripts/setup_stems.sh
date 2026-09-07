#!/usr/bin/env bash
set -euo pipefail
stems_backend=$(cd "$(dirname "$0")/.." && pwd)
stems_root=${1:-$stems_backend/.stems}
stems_python=${PYTHON:-python3.11}
mkdir -p "$stems_root"
"$stems_python" -m venv "$stems_root/venv"
if [[ "$(uname -s)" == Linux ]]; then
  "$stems_root/venv/bin/python" -m pip install --extra-index-url https://download.pytorch.org/whl/cpu -r "$stems_backend/requirements-stems.txt"
else
  "$stems_root/venv/bin/python" -m pip install -r "$stems_backend/requirements-stems.txt"
fi
# Official Demucs filename embeds the checkpoint's SHA-256 prefix; Torch verifies it.
TORCH_HOME="$stems_root/torch" "$stems_root/venv/bin/python" - <<'PY'
from demucs.pretrained import get_model
model = get_model('htdemucs_6s')
assert set(model.sources) == {'drums', 'bass', 'other', 'vocals', 'guitar', 'piano'}
print('Verified htdemucs_6s model and instrument set')
PY
