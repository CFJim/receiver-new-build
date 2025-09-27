#!/usr/bin/env bash
set -euo pipefail
cd ~/clearframe
if [ -f run/clearframe.pid ] && ps -p "$(cat run/clearframe.pid)" >/dev/null 2>&1; then
  kill "$(cat run/clearframe.pid)" || true
  sleep 0.3
  if ps -p "$(cat run/clearframe.pid)" >/dev/null 2>&1; then
    kill -9 "$(cat run/clearframe.pid)" || true
  fi
  rm -f run/clearframe.pid
  echo "[RX] stopped"
else
  echo "[RX] not running"
fi
