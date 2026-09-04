#!/usr/bin/env bash
# Installs the pinned ISMIR recognizer for both API practice and ingest.
# Keeps its dependency environment separate from madmom/FastAPI. Repeated
# installs retain local compatibility edits but refuse an unrelated revision.
#
#   backend/scripts/setup_ismir.sh [target-dir]   # default ~/.chordlyze/ismir2019
set -euo pipefail

TARGET="${1:-${CHORDLYZE_ISMIR_DIR:-$HOME/.chordlyze/ismir2019}}"
REPO="https://github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition.git"
PYTHON="${PYTHON:-python3.11}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"
REVISION="$(PYTHONPATH="$BACKEND_DIR" "$PYTHON" -c 'from chordlyze_backend.analysis.provenance import ISMIR_COMMIT; print(ISMIR_COMMIT)')"

if [ ! -d "$TARGET/.git" ]; then
    mkdir -p "$(dirname "$TARGET")"
    git clone --no-checkout "$REPO" "$TARGET"
    git -C "$TARGET" checkout --detach "$REVISION"
elif [ "$(git -C "$TARGET" rev-parse HEAD)" != "$REVISION" ]; then
    echo "Model checkout has another revision. Install into a new target directory: $REVISION" >&2
    exit 1
fi

# numpy 2 removed the np.int / np.float / np.bool aliases the 2019 code uses.
find "$TARGET" -name '*.py' -not -path '*/.venv/*' -print0 \
    | xargs -0 perl -pi -e 's/\bnp\.int\b(?![0-9_])/int/g; s/\bnp\.float\b(?![0-9_])/float/g; s/\bnp\.bool\b(?![0-9_])/bool/g'

if [ ! -x "$TARGET/.venv/bin/python" ]; then
    "$PYTHON" -m venv "$TARGET/.venv"
fi
# Linux deployment uses CPU wheels so pip does not pull CUDA into the image.
if [ "$(uname -s)" = "Linux" ]; then
    TORCH_REQUIREMENT="$(sed -n '/^torch==/p' "$BACKEND_DIR/requirements-ismir.txt")"
    "$TARGET/.venv/bin/pip" install --quiet --index-url https://download.pytorch.org/whl/cpu "$TORCH_REQUIREMENT"
fi
"$TARGET/.venv/bin/pip" install --quiet -r "$BACKEND_DIR/requirements-ismir.txt"

# Verify every checkpoint and the dictionary, and actually load the ensemble.
# EOF exits the private worker after its ready response.
(
    cd "$TARGET"
    PYTHONPATH="$BACKEND_DIR" PYTHONDONTWRITEBYTECODE=1 \
        .venv/bin/python -m chordlyze_backend.analysis.ismir_worker </dev/null
)
