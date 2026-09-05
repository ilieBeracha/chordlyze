"""Install the on-demand worker as a macOS per-user LaunchAgent.

Run with the backend's Python environment. Secrets stay in .env.worker;
the plist contains paths only. Re-running replaces this one service.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys

LABEL = 'com.chordlyze.song-worker'


def configuration(backend: Path, python: str) -> dict:
    return {
        'Label': LABEL,
        'ProgramArguments': [python, '-u', str(backend / 'song_worker.py'), '--env', str(backend / '.env.worker')],
        'WorkingDirectory': str(backend),
        'RunAtLoad': True,
        'KeepAlive': True,
        'ThrottleInterval': 15,
        'ProcessType': 'Background',
        'StandardOutPath': str(backend / 'worker-logs' / 'worker.log'),
        'StandardErrorPath': str(backend / 'worker-logs' / 'worker-error.log'),
        'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin',
                                 'PYTHONUNBUFFERED': '1'},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Install and start; otherwise show paths only.')
    args = parser.parse_args()
    backend = Path(__file__).resolve().parents[1]
    # Preserve the venv executable path (resolving its symlink bypasses the venv).
    config = configuration(backend, sys.executable)
    destination = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
    if not args.apply:
        print(f'Worker: {backend / "song_worker.py"}\nLaunchAgent: {destination}')
        return
    env = backend / '.env.worker'
    if not env.is_file() or env.stat().st_mode & 0o077:
        raise SystemExit('Create .env.worker with owner-only permissions (chmod 600) first.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    (backend / 'worker-logs').mkdir(mode=0o700, exist_ok=True)
    domain = f'gui/{os.getuid()}'
    subprocess.run(['launchctl', 'bootout', f'{domain}/{LABEL}'], capture_output=True)
    destination.write_bytes(plistlib.dumps(config))
    destination.chmod(0o600)
    subprocess.run(['launchctl', 'bootstrap', domain, str(destination)], check=True)
    subprocess.run(['launchctl', 'kickstart', f'{domain}/{LABEL}'], check=True)
    print('On-demand song worker installed and started.')


if __name__ == '__main__':
    main()
