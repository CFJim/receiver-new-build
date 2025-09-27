#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."
mkdir -p logs
[ -f .venv/bin/activate ] && . .venv/bin/activate
python app.py 2>&1 | tee -a logs/clearframe.log
