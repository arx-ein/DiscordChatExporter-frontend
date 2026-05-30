#!/bin/bash
# DCEF Linux launcher — equivalent of dcef.exe on Windows.
# Place this script (as dcef.sh) in the release root alongside dcef/, exports/, etc.
#
# Requirements: nginx (system-installed)
#   Ubuntu/Debian: sudo apt install nginx
#   Fedora/RHEL:   sudo dnf install nginx
#   Arch:          sudo pacman -S nginx

set -e

DCEF_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"

# ── Single-instance lock ──────────────────────────────────────────────────────
LOCK_FILE="/tmp/dcef.lock"
if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
    echo "DCEF is already running (PID $(cat "$LOCK_FILE")). Exiting."
    exit 1
fi
echo $$ > "$LOCK_FILE"

# ── Cleanup on exit / Ctrl-C ──────────────────────────────────────────────────
NGINX_PID="" FASTAPI_PID="" MONGODB_PID=""
cleanup() {
    echo ""
    echo "Shutting down DCEF..."
    [ -n "$NGINX_PID"   ] && kill "$NGINX_PID"   2>/dev/null || true
    [ -n "$FASTAPI_PID" ] && kill "$FASTAPI_PID" 2>/dev/null || true
    [ -n "$MONGODB_PID" ] && kill "$MONGODB_PID" 2>/dev/null || true
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT INT TERM

# ── Prerequisites ─────────────────────────────────────────────────────────────
if ! command -v nginx &>/dev/null; then
    echo "ERROR: nginx is not installed."
    echo "  Ubuntu/Debian: sudo apt install nginx"
    echo "  Fedora/RHEL:   sudo dnf install nginx"
    echo "  Arch:          sudo pacman -S nginx"
    exit 1
fi

# ── Required directories ──────────────────────────────────────────────────────
mkdir -p "$DCEF_DIR/_temp/db" \
         "$DCEF_DIR/_temp/nginx" \
         "$DCEF_DIR/exports" \
         "$DCEF_DIR/logs"

# ── Generate nginx config with absolute paths ─────────────────────────────────
# nginx has no env-var support, so the template uses DCEF_DIR as a literal
# placeholder that sed replaces with the real path at startup.
NGINX_CONF="$DCEF_DIR/_temp/nginx/nginx.conf"
sed "s|DCEF_DIR|$DCEF_DIR|g" \
    "$DCEF_DIR/dcef/backend/nginx/conf/nginx-linux-prod.conf" > "$NGINX_CONF"

# ── Port availability check ───────────────────────────────────────────────────
port_in_use() { (echo > /dev/tcp/127.0.0.1/"$1") 2>/dev/null; }

for port in 21011 58000 27017; do
    if port_in_use "$port"; then
        echo "ERROR: Port $port is already in use. Is another DCEF instance running?"
        exit 1
    fi
done

wait_for_port() {
    local port=$1 i
    for i in $(seq 1 30); do
        port_in_use "$port" && return 0
        sleep 1
    done
    echo "ERROR: Timed out waiting for port $port to become available."
    exit 1
}

# ── MongoDB ───────────────────────────────────────────────────────────────────
echo "Starting MongoDB..."
"$DCEF_DIR/dcef/backend/mongodb/dcefmongod" \
    --dbpath "$DCEF_DIR/_temp/db" \
    --wiredTigerCacheSizeGB 1.5 \
    >> "$DCEF_DIR/logs/mongodb.log" 2>&1 &
MONGODB_PID=$!

wait_for_port 27017
echo "MongoDB ready."

# ── Preprocess (index exports, blocking — same as Docker run_container.sh) ────
echo "Indexing exports (may take a while on first run)..."
(cd "$DCEF_DIR/dcef/backend/preprocess" && ./dcefpreprocess linux)
echo "Preprocess done."

# ── FastAPI ───────────────────────────────────────────────────────────────────
echo "Starting FastAPI..."
(cd "$DCEF_DIR/dcef/backend/fastapi" && ./dceffastapi) \
    >> "$DCEF_DIR/logs/fastapi.log" 2>&1 &
FASTAPI_PID=$!

wait_for_port 58000
echo "FastAPI ready."

# ── nginx ─────────────────────────────────────────────────────────────────────
# daemon off; is set in the config — nginx stays in the foreground (as a shell
# background job here), which lets us track its PID and kill it on exit.
echo "Starting nginx..."
nginx -c "$NGINX_CONF" >> "$DCEF_DIR/logs/nginx.log" 2>&1 &
NGINX_PID=$!
sleep 1

echo ""
echo "############################################################"
echo "# Open http://127.0.0.1:21011/ in your browser            #"
echo "############################################################"
echo ""

xdg-open "http://127.0.0.1:21011/" 2>/dev/null || true

# nginx is the "main" process — wait on it; EXIT trap kills the others.
wait "$NGINX_PID"
