#!/usr/bin/env bash
# Installs the ISMIR2019 large-vocabulary chord recognizer for the ingest
# worker: clones the official repo, patches its numpy-1.x aliases, and builds
# an isolated venv (PyTorch, librosa). Idempotent. ~2 minutes, ~1 GB.
#
#   backend/scripts/setup_ismir.sh [target-dir]   # default ~/.chordlyze/ismir2019
set -euo pipefail

TARGET="${1:-$HOME/.chordlyze/ismir2019}"
REPO="https://github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition.git"
PYTHON="${PYTHON:-python3.11}"

if [ ! -d "$TARGET/.git" ]; then
    mkdir -p "$(dirname "$TARGET")"
    git clone --depth 1 "$REPO" "$TARGET"
fi

# numpy 2 removed the np.int / np.float / np.bool aliases the 2019 code uses.
find "$TARGET" -name '*.py' -not -path '*/.venv/*' -print0 \
    | xargs -0 perl -pi -e 's/\bnp\.int\b(?![0-9_])/int/g; s/\bnp\.float\b(?![0-9_])/float/g; s/\bnp\.bool\b(?![0-9_])/bool/g'

if [ ! -x "$TARGET/.venv/bin/python" ]; then
    "$PYTHON" -m venv "$TARGET/.venv"
fi
"$TARGET/.venv/bin/pip" install --quiet --upgrade pip
"$TARGET/.venv/bin/pip" install --quiet torch librosa numpy joblib mir_eval pretty_midi h5py pumpp jams scikit-learn pydub soundfile

"$TARGET/.venv/bin/python" -c "import torch, librosa, pumpp; print('ISMIR2019 ready:', '$TARGET')"
