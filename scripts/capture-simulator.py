#!/usr/bin/env python3
"""Capture the real simulator UI on a disposable CI simulator; never a phone."""
import json
import subprocess
import sys
import time
from pathlib import Path

def run(*args, timeout=60):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True, timeout=timeout).strip()

app, output = map(Path, sys.argv[1:])
runtimes = json.loads(run('list', 'runtimes', '-j'))['runtimes']
runtime = next(r['identifier'] for r in reversed(runtimes) if r['isAvailable'] and 'iOS' in r['name'])
types = json.loads(run('list', 'devicetypes', '-j'))['devicetypes']
device_type = next(d['identifier'] for d in types if d['name'] == 'iPhone 16')
device = run('create', 'MotoLink visual check', device_type, runtime)
try:
    run('boot', device)
    run('bootstatus', device, '-b', timeout=180)
    run('ui', device, 'appearance', 'dark')
    run('status_bar', device, 'override', '--time', '9:41', '--batteryState', 'charged', '--batteryLevel', '100')
    run('install', device, str(app))
    run('launch', device, 'org.koltenberg.MotoLink')
    time.sleep(5)
    run('io', device, 'screenshot', str(output / 'simulator-home.png'))
    # Dynamic Type should keep the main screen scrollable and labels legible.
    run('ui', device, 'content_size', 'accessibility-large')
    time.sleep(2)
    run('io', device, 'screenshot', str(output / 'simulator-large-text.png'))
finally:
    subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True, timeout=30)
    subprocess.run(['xcrun', 'simctl', 'delete', device], capture_output=True, timeout=30)
