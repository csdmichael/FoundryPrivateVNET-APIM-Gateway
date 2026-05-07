#!/bin/bash
set -e

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || command -v python)}"

if [ ! -f /home/site/deps/.ready ]; then
  rm -rf /home/site/deps
  mkdir -p /home/site/deps
  "$PYTHON_BIN" -m pip install --no-cache-dir -r /home/site/wwwroot/requirements.txt -t /home/site/deps
  touch /home/site/deps/.ready
fi

export PYTHONPATH=/home/site/wwwroot:/home/site/deps:$PYTHONPATH
exec "$PYTHON_BIN" -m gunicorn --bind=0.0.0.0:${PORT:-8000} --timeout 600 -k aiohttp.GunicornWebWorker bot_app:app