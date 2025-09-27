#!/usr/bin/env bash
set -euo pipefail
cd ~/clearframe
echo "UARTs:"; ls -l /dev/ttyAMA* /dev/serial* 2>/dev/null || true
ROLE=$(python - <<'PY'
import json, os
p=os.path.expanduser('~/clearframe/config/settings.json')
try:
    d=json.load(open(p)); print(d.get('mode',{}).get('role','?'))
except Exception: print('?')
PY
)
echo "role: $ROLE"
if [ -f run/clearframe.pid ] && ps -p "$(cat run/clearframe.pid)" >/dev/null 2>&1; then
  echo "app: running (pid $(cat run/clearframe.pid))"
else
  echo "app: not running"
fi
echo "--- last 15 log lines ---"
[ -f logs/clearframe.log ] && tail -n 15 logs/clearframe.log || echo "(no log yet)"
