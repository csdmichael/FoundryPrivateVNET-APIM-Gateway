#!/bin/bash
set -e

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || command -v python)}"

# Re-install dependencies whenever requirements.txt changes. We key the
# /home/site/deps cache on the sha256 of requirements.txt so a deploy that
# bumps a package version is actually picked up (the old check only looked
# for a .ready flag, which never invalidated).
REQ_FILE=/home/site/wwwroot/requirements.txt
HASH_FILE=/home/site/deps/.req-hash
REQ_HASH=$(sha256sum "$REQ_FILE" | awk '{print $1}')

if [ ! -f "$HASH_FILE" ] || [ "$(cat "$HASH_FILE" 2>/dev/null)" != "$REQ_HASH" ]; then
  echo "[startup] requirements.txt changed (or first run); installing deps..."
  rm -rf /home/site/deps
  mkdir -p /home/site/deps
  "$PYTHON_BIN" -m pip install --no-cache-dir -r "$REQ_FILE" -t /home/site/deps
  echo "$REQ_HASH" > "$HASH_FILE"
  echo "[startup] deps installed."
else
  echo "[startup] deps cache hit ($REQ_HASH); skipping pip install."
fi

export PYTHONPATH=/home/site/wwwroot:/home/site/deps:$PYTHONPATH
exec "$PYTHON_BIN" -m gunicorn \
  --bind=0.0.0.0:${PORT:-8000} \
  --timeout 600 \
  --access-logfile - \
  --error-logfile - \
  --log-level info \
  -k aiohttp.GunicornWebWorker \
  bot_app:app
