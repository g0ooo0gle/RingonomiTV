#!/usr/bin/env python3
"""Check application handoff state on macOS using the real SwiftUI store."""
from pathlib import Path
import os
import platform
import subprocess

root = Path(__file__).resolve().parents[2]
build = Path(os.environ.get('APP_STATE_CHECK_BUILD_DIR', root / '.build/app-state-checks'))
build.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
subprocess.run([compiler, '-parse-as-library', '-swift-version', '6',
                '-strict-concurrency=complete', '-sdk', sdk,
                '-target', platform.machine() + '-apple-macosx14.0',
                '-module-cache-path', str(build / 'module-cache'),
                str(root / 'App/PlaybackPresentationStore.swift'),
                str(root / 'Tests/AppStateChecks/PlaybackPresentationCheck.swift'),
                '-o', str(build / 'presentation-check')], check=True)
subprocess.run([str(build / 'presentation-check')], check=True)
