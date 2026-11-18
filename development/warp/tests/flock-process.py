#!/usr/bin/env python3
"""Check util-linux flock -F process ownership locally, without network access."""
import pathlib, subprocess, tempfile, time
with tempfile.TemporaryDirectory() as d:
    lock=pathlib.Path(d)/'lock'; marker=pathlib.Path(d)/'pid'
    proc=subprocess.Popen(['flock','-F','-n',str(lock),'sh','-c','echo $$ > "$1"; exec sleep 30','sh',str(marker)])
    try:
        for _ in range(100):
            if marker.exists() and marker.stat().st_size: break
            time.sleep(.02)
        assert marker.exists() and int(marker.read_text())==proc.pid, 'flock forked the helper'
        assert subprocess.run(['flock','-n',str(lock),'true']).returncode!=0, 'lock not held'
        proc.terminate(); proc.wait(timeout=5)
        assert subprocess.run(['flock','-n',str(lock),'true']).returncode==0, 'lock not released'
        print('PASS: local flock -F keeps the helper PID and releases its lock on termination')
    finally:
        if proc.poll() is None:
            proc.kill(); proc.wait(timeout=5)
