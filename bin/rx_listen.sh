#!/usr/bin/env bash
set -euo pipefail

cd ~/clearframe
mkdir -p logs

# show UARTs (just informational)
ls -l /dev/ttyAMA* /dev/serial* 2>/dev/null || true

# show current role from settings
ROLE=$(python - <<'PY'
import json, os
p=os.path.expanduser('~/clearframe/config/settings.json')
try:
    d=json.load(open(p))
    print(d.get('mode',{}).get('role','?'))
except Exception:
    print('?')
PY
)
echo "[config] role=$ROLE (expect 'receiver')"

# start fresh log and launch app
: > logs/clearframe.log
./bin/run_clearframe.sh &

APP_PID=$!
echo "[RX] listening (pid $APP_PID). Ctrl+C stops the tail (app keeps running)."
trap 'echo; echo "[RX] tail stopped"; exit 0' INT

# follow only new lines
tail -n0 -F logs/clearframe.log
