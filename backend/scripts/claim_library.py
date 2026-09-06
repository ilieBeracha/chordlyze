"""One-time migration: give every chart that exists today to one user.

Before per-user libraries, every chart on the server belonged to whoever
asked. Run once on the server for the account that did:

    python scripts/claim_library.py <spotify-user-id>
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from chordlyze_backend.song_jobs import library_lock  # noqa: E402
from chordlyze_backend.users import UserLibrary  # noqa: E402


def main() -> None:
    if len(sys.argv) != 2 or not sys.argv[1]:
        sys.exit(__doc__)
    cache = Path(os.environ.get("CHORDLYZE_CACHE",
                                str(Path(__file__).resolve().parents[1] / "analysis_cache")))
    library = UserLibrary(cache, sys.argv[1])
    with library_lock(cache):
        paths = sorted(cache.glob("track-*.json"), key=lambda p: p.stat().st_mtime)
        added = sum(library.add(path.stem.removeprefix("track-"), now=path.stat().st_mtime) for path in paths)
    print(f"{added} of {len(paths)} charts added to {sys.argv[1]}'s library")


if __name__ == "__main__":
    main()
