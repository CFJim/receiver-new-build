#!/usr/bin/env bash
set -euo pipefail
cd ~/clearframe
mkdir -p logs run
: > logs/clearframe.log
# don’t double-start
if [ -f run/clearframe.pid ] && ps -p "$(cat run/clearframe.pid)" >/dev/null 2>&1; then
  echo "[RX] already running (pid $(cat run/clearframe.pid))"
  exit 0
fi
# start app in background and record pid
( ./bin/run_clearframe.sh & echo $! > run/clearframe.pid ) &
sleep 0.6
echo "[RX] started. pid=$(cat run/clearframe.pid)"
