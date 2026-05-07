#!/bin/bash
# API App Service startup script.
# Installs Python deps on first boot, then starts gunicorn.

set -e

DEPS_DIR="/home/site/deps"
READY_FLAG="$DEPS_DIR/.ready"
REQUIREMENTS="/home/site/wwwroot/requirements.txt"

if [ ! -f "$READY_FLAG" ]; then
    echo "Installing Python dependencies..."
    rm -rf "$DEPS_DIR"
    mkdir -p "$DEPS_DIR"
    python -m pip install --no-cache-dir --prefer-binary -r "$REQUIREMENTS" -t "$DEPS_DIR"
    touch "$READY_FLAG"
    echo "Dependencies installed."
else
    echo "Dependencies already installed, skipping pip install."
fi

export PYTHONPATH="$DEPS_DIR:${PYTHONPATH:-}"

echo "Starting gunicorn on port ${PORT:-8000}..."
exec gunicorn --bind=0.0.0.0:${PORT:-8000} --timeout 600 -k uvicorn.workers.UvicornWorker server:app
