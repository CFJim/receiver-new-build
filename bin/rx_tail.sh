#!/usr/bin/env bash
set -euo pipefail
cd ~/clearframe
mkdir -p logs
echo "[RX] tailing logs (Ctrl+C to stop tail; app keeps running)"
tail -n0 -F logs/clearframe.log
