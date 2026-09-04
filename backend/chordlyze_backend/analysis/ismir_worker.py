"""Private JSON-lines inference worker, run in the pinned ISMIR environment.

The process working directory is the model checkout because the upstream
loader resolves checkpoint paths relative to it. All network weights are
verified before loading; missing files must never produce random predictions.
"""
from __future__ import annotations

import contextlib
import hashlib
import json
import os
import sys
from pathlib import Path

from .provenance import ISMIR_VOCABULARY_HASH, ISMIR_WEIGHT_HASHES


def _check(path: Path, expected: str) -> None:
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise RuntimeError(f"missing or incompatible model asset: {path.name}")


def main() -> None:
    try:
        root = Path.cwd()
        names = [f"joint_chord_net_ismir_naive_v1.0_reweight(0.0,10.0)_s{i}.best" for i in range(5)]
        for name, digest in zip(names, ISMIR_WEIGHT_HASHES):
            _check(root / "cache_data" / f"{name}.sdict", digest)
        _check(root / "data/submission_chord_list.txt", ISMIR_VOCABULARY_HASH)
        sys.path.insert(0, str(root))
        with contextlib.redirect_stdout(sys.stderr):
            import numpy as np
            import torch
            from chordnet_ismir_naive import ChordNet
            from extractors.cqt import CQTV2
            from extractors.xhmm_ismir import XHMMDecoder
            from mir import DataEntry, io
            from mir.nn.train import NetworkInterface
            from settings import DEFAULT_SR, DEFAULT_HOP_LENGTH

            torch.set_num_threads(int(os.environ.get("CHORDLYZE_TORCH_THREADS", "2")))
            networks = [NetworkInterface(ChordNet(None), name, load_checkpoint=False) for name in names]
            if not all(net.finalized for net in networks):
                raise RuntimeError("model checkpoints were not loaded")
            decoder = XHMMDecoder(template_file="data/submission_chord_list.txt")
        print(json.dumps({"ready": True}), flush=True)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}), flush=True)
        raise SystemExit(1)

    for line in sys.stdin:
        try:
            request = json.loads(line)
            with contextlib.redirect_stdout(sys.stderr):
                entry = DataEntry()
                entry.prop.set("sr", DEFAULT_SR)
                entry.prop.set("hop_length", DEFAULT_HOP_LENGTH)
                entry.append_file(request["path"], io.MusicIO, "music")
                entry.append_extractor(CQTV2, "cqt")
                predictions = [net.inference(entry.cqt) for net in networks]
                probs = [np.mean([p[i] for p in predictions], axis=0)
                         for i in range(len(predictions[0]))]
                rows = decoder.decode_to_chordlab(entry, probs, False)
            print(json.dumps({"segments": [[float(a), float(b), str(c)] for a, b, c in rows]},
                             allow_nan=False), flush=True)
        except Exception as exc:
            print(json.dumps({"error": str(exc)}), flush=True)


if __name__ == "__main__":
    main()
