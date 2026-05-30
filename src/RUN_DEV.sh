#!/bin/bash
# Linux dev environment — equivalent of RUN_DEV.bat.
# Starts all five services (MongoDB, preprocess, FastAPI, Vite, nginx) and
# prints their combined output to the terminal with a [service] prefix.
#
# Requirements:
#   - mongod  (system-installed MongoDB — any 6.x build)
#   - nginx   (system-installed)
#   - python3.11 (or python3)
#   - node.js v18+, npm
#
# Exports directory (for /input/ assets in the browser):
#   By default points to src/exports/
#   Override with DCEF_EXPORTS_DIR env var.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Config ────────────────────────────────────────────────────────────────────
PYTHON=python3.11
command -v "$PYTHON" &>/dev/null || PYTHON=python3

EXPORTS_DIR="${DCEF_EXPORTS_DIR:-$SCRIPT_DIR/exports}"
MONGODB_DATA="$SCRIPT_DIR/_temp/mongodb"

# ── Prerequisites ─────────────────────────────────────────────────────────────
for cmd in mongod nginx; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is not installed."
        [ "$cmd" = "mongod" ] && echo "  Ubuntu/Debian: sudo apt install mongodb-org"
        [ "$cmd" = "nginx"  ] && echo "  Ubuntu/Debian: sudo apt install nginx"
        exit 1
    fi
done

# ── Venvs (created once, like RUN_DEV.bat) ────────────────────────────────────
if [ ! -d "_temp/fastapi/venv" ]; then
    echo "Creating FastAPI venv..."
    $PYTHON -m venv _temp/fastapi/venv
    _temp/fastapi/venv/bin/pip install -r dcef/backend/fastapi/requirements.txt
fi

if [ ! -d "_temp/preprocess/venv" ]; then
    echo "Creating preprocess venv..."
    $PYTHON -m venv _temp/preprocess/venv
    _temp/preprocess/venv/bin/pip install -r dcef/backend/preprocess/requirements.txt
fi

cd dcef/frontend
[ ! -d "node_modules" ] && npm install
cd "$SCRIPT_DIR"

# ── Required directories ──────────────────────────────────────────────────────
mkdir -p "$MONGODB_DATA" logs _temp/nginx
mkdir -p "$EXPORTS_DIR"

# ── Generate nginx dev config with absolute paths ─────────────────────────────
# nginx-linux-dev.conf uses two placeholders:
#   DCEF_DIR    → script directory (for pid, error_log, mime.types)
#   EXPORTS_DIR → configurable exports path (overridable via $DCEF_EXPORTS_DIR)
NGINX_CONF="$SCRIPT_DIR/_temp/nginx/nginx-dev.conf"
sed \
    -e "s|DCEF_DIR|$SCRIPT_DIR|g" \
    -e "s|EXPORTS_DIR|$EXPORTS_DIR|g" \
    "$SCRIPT_DIR/dcef/backend/nginx/conf/nginx-linux-dev.conf" > "$NGINX_CONF"

# ── Cleanup on exit ───────────────────────────────────────────────────────────
PIDS=()
cleanup() {
    echo ""
    echo "Shutting down dev services..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

# ── Prefixed output helper ─────────────────────────────────────────────────────
# Usage: run_bg <label> <working_dir> <cmd> [args...]
# Mirrors RUN_DEV.bat's per-pane -d <dir> flag: each service gets its own CWD
# so relative paths inside each service resolve correctly.
run_bg() {
    local label=$1 dir=$2; shift 2
    (cd "$dir" && "$@" 2>&1 | sed -u "s/^/[$label] /") &
    PIDS+=($!)
}

# ── MongoDB ───────────────────────────────────────────────────────────────────
echo "Starting MongoDB (data: $MONGODB_DATA)..."
run_bg "mongodb" "$SCRIPT_DIR" mongod \
    --dbpath "$MONGODB_DATA" \
    --wiredTigerCacheSizeGB 1

# Wait for MongoDB before running preprocess
echo "Waiting for MongoDB on port 27017..."
for i in $(seq 1 30); do
    (echo > /dev/tcp/127.0.0.1/27017) 2>/dev/null && break
    sleep 1
done

# ── Preprocess (run once synchronously) ───────────────────────────────────────
# In RUN_DEV.bat, preprocess runs under nodemon (restarts on .py file changes).
# Here we run it once; restart manually if you change preprocess source files.
echo "Running preprocess..."
(cd "$SCRIPT_DIR/dcef/backend/preprocess" && \
    "$SCRIPT_DIR/_temp/preprocess/venv/bin/python" main_mongo.py windows)
echo "Preprocess done."

# ── FastAPI dev server (port 58001, reload=True) ──────────────────────────────
# CWD must be the fastapi directory: the code opens "src/search/search_categories.json"
# as a relative path, matching how RUN_DEV.bat sets -d to the fastapi folder.
run_bg "fastapi" "$SCRIPT_DIR/dcef/backend/fastapi" \
    "$SCRIPT_DIR/_temp/fastapi/venv/bin/python" dev.py

# ── Vite frontend dev server (port 5050) ──────────────────────────────────────
run_bg "vite" "$SCRIPT_DIR/dcef/frontend" \
    npm run dev

# ── nginx reverse proxy (port 21012) ──────────────────────────────────────────
run_bg "nginx" "$SCRIPT_DIR" \
    nginx -c "$NGINX_CONF"

echo ""
echo "Dev environment running."
echo "  App:      http://127.0.0.1:21012/"
echo "  FastAPI:  http://127.0.0.1:58001/docs"
echo "  Vite:     http://127.0.0.1:5050/"
echo "  Exports:  $EXPORTS_DIR"
echo ""
echo "Press Ctrl-C to stop all services."
echo ""

xdg-open "http://127.0.0.1:21012/" 2>/dev/null || true

wait