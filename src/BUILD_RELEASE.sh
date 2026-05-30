#!/bin/bash
# Linux native build script for DiscordChatExporter-frontend
# Equivalent of BUILD_RELEASE.bat — produces a self-contained release/ folder.
#
# Requirements:
#   - python3.11 (falls back to python3 if not found)
#   - pip / venv (python3-venv on Debian/Ubuntu)
#   - node.js v18+, npm
#   - pyinstaller  (installed automatically into each venv)
#   - wget + tar   (for downloading the MongoDB binary)
#   - nginx        (runtime requirement, not bundled — documented in output)
#
# Usage:
#   bash src/BUILD_RELEASE.sh
#
# To force a clean rebuild, delete src/_temp/ first.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RELEASE_DIR="$SCRIPT_DIR/../release"

# ── Python interpreter ────────────────────────────────────────────────────────
# Match the version used in the Dockerfile (python3.11) where possible.
PYTHON=python3.11
if ! command -v "$PYTHON" &>/dev/null; then
    echo "WARNING: python3.11 not found, falling back to python3"
    PYTHON=python3
fi
echo "Using: $($PYTHON --version)"

# ── Kill any lingering DCEF processes ─────────────────────────────────────────
pkill -f "dceffastapi"   2>/dev/null || true
pkill -f "dcefpreprocess" 2>/dev/null || true
pkill -f "dcefmongod"    2>/dev/null || true

mkdir -p _temp


# ── Preprocess ────────────────────────────────────────────────────────────────
# Indexes Discord exports into MongoDB at runtime.
# PyInstaller compiles it to a single binary so end-users need no Python.

if [ ! -d "_temp/preprocess/venv" ]; then
    $PYTHON -m venv _temp/preprocess/venv
    _temp/preprocess/venv/bin/pip install -r dcef/backend/preprocess/requirements.txt
fi

_temp/preprocess/venv/bin/python -m PyInstaller \
    --onefile --name preprocess \
    --distpath "_temp/preprocess/" \
    --specpath "_temp/preprocess/" \
    --workpath "_temp/preprocess/build/" \
    ./dcef/backend/preprocess/main_mongo.py

rm -rf "$RELEASE_DIR/dcef/backend/preprocess/"
mkdir -p "$RELEASE_DIR/dcef/backend/preprocess/"
mv _temp/preprocess/preprocess "$RELEASE_DIR/dcef/backend/preprocess/dcefpreprocess"
cp dcef/backend/preprocess/emojiIndex.json \
   "$RELEASE_DIR/dcef/backend/preprocess/emojiIndex.json"


# ── FastAPI backend ───────────────────────────────────────────────────────────
# uvicorn hidden imports are required by PyInstaller because uvicorn uses
# importlib to load its components dynamically at runtime.

if [ ! -d "_temp/fastapi/venv" ]; then
    $PYTHON -m venv _temp/fastapi/venv
    _temp/fastapi/venv/bin/pip install -r dcef/backend/fastapi/requirements.txt
fi

_temp/fastapi/venv/bin/python -m PyInstaller \
    --onefile --name fastapi \
    --distpath "_temp/fastapi/" \
    --specpath "_temp/fastapi/" \
    --workpath "_temp/fastapi/build/" \
    ./dcef/backend/fastapi/prod.py \
    -F \
    --hidden-import "uvicorn.logging" \
    --hidden-import "uvicorn.loops" \
    --hidden-import "uvicorn.loops.auto" \
    --hidden-import "uvicorn.protocols" \
    --hidden-import "uvicorn.protocols.http" \
    --hidden-import "uvicorn.protocols.http.auto" \
    --hidden-import "uvicorn.protocols.websockets" \
    --hidden-import "uvicorn.protocols.websockets.auto" \
    --hidden-import "uvicorn.lifespan" \
    --hidden-import "uvicorn.lifespan.on" \
    --hidden-import "src.main"

rm -rf "$RELEASE_DIR/dcef/backend/fastapi/"
mkdir -p "$RELEASE_DIR/dcef/backend/fastapi/src/search/"
mv _temp/fastapi/fastapi "$RELEASE_DIR/dcef/backend/fastapi/dceffastapi"
cp dcef/backend/fastapi/src/search/search_categories.json \
   "$RELEASE_DIR/dcef/backend/fastapi/src/search/search_categories.json"


# ── Frontend (SvelteKit → Vite static build) ──────────────────────────────────
# vite.config.ts outputs to ../../_temp/frontend (relative to src/dcef/frontend/),
# which resolves to src/_temp/frontend/.

cd dcef/frontend
[ ! -d "node_modules" ] && npm install
npm run build
cd "$SCRIPT_DIR"

rm -rf "$RELEASE_DIR/dcef/frontend/"
mv _temp/frontend "$RELEASE_DIR/dcef/frontend"


# ── nginx config ──────────────────────────────────────────────────────────────
# nginx itself is NOT bundled — it must be installed system-wide.
# The config uses DCEF_DIR as a placeholder; dcef.sh substitutes the real path
# at runtime via sed so nginx gets absolute paths regardless of install location.

mkdir -p "$RELEASE_DIR/dcef/backend/nginx/conf/"
cp dcef/backend/nginx/conf/nginx-linux-prod.conf \
   "$RELEASE_DIR/dcef/backend/nginx/conf/nginx-linux-prod.conf"
cp dcef/backend/nginx/conf/mime.types \
   "$RELEASE_DIR/dcef/backend/nginx/conf/mime.types"


# ── MongoDB binary ────────────────────────────────────────────────────────────
# Download the official MongoDB tarball for Linux so the release is self-contained.
# Only mongod is extracted; mongos and other tools are omitted.
# Version matches the Dockerfile base image (mongo:6.0.5-jammy).

MONGO_VERSION="6.0.5"
MONGO_DEST="$RELEASE_DIR/dcef/backend/mongodb/dcefmongod"
mkdir -p "$RELEASE_DIR/dcef/backend/mongodb/"

if [ ! -f "$MONGO_DEST" ]; then
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)
            MONGO_URL="https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu2204-${MONGO_VERSION}.tgz"
            MONGO_BIN="mongodb-linux-x86_64-ubuntu2204-${MONGO_VERSION}/bin/mongod"
            ;;
        aarch64|arm64)
            MONGO_URL="https://fastdl.mongodb.org/linux/mongodb-linux-aarch64-ubuntu2204-${MONGO_VERSION}.tgz"
            MONGO_BIN="mongodb-linux-aarch64-ubuntu2204-${MONGO_VERSION}/bin/mongod"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $ARCH"
            echo "       Download mongod manually from https://www.mongodb.com/try/download/community"
            echo "       and place it at: $MONGO_DEST"
            exit 1
            ;;
    esac

    echo "Downloading MongoDB $MONGO_VERSION for $ARCH..."
    mkdir -p _temp/mongodb
    wget --show-progress -O _temp/mongodb.tgz "$MONGO_URL"
    # Extract only the mongod binary from the tarball (the archive is ~300 MB,
    # mongod itself ~180 MB; mongos and other tools are not needed here).
    tar -xzf _temp/mongodb.tgz -C _temp/mongodb/ --strip-components=2 "$MONGO_BIN"
    mv _temp/mongodb/mongod "$MONGO_DEST"
    chmod +x "$MONGO_DEST"
fi


# ── Launcher script ───────────────────────────────────────────────────────────
# Shell-script equivalent of dcef.exe — starts all services and opens the browser.

cp dcef/backend/linux/run.sh "$RELEASE_DIR/dcef.sh"
chmod +x "$RELEASE_DIR/dcef.sh"


# ── Scaffold empty runtime dirs ───────────────────────────────────────────────

rm -rf "$RELEASE_DIR/logs/"  && mkdir -p "$RELEASE_DIR/logs/"
rm -rf "$RELEASE_DIR/temp/"  && mkdir -p "$RELEASE_DIR/temp/"
[ ! -d "$RELEASE_DIR/exports" ] && mkdir -p "$RELEASE_DIR/exports"


echo ""
echo "Build complete!"
echo ""
echo "Release folder: $RELEASE_DIR"
echo ""
echo "Next steps:"
echo "  1. Install nginx if not already present:"
echo "       Ubuntu/Debian: sudo apt install nginx"
echo "       Fedora/RHEL:   sudo dnf install nginx"
echo "       Arch:          sudo pacman -S nginx"
echo "  2. Place your Discord exports (.json + attachment folders) in:"
echo "       $RELEASE_DIR/exports/"
echo "  3. Run:  $RELEASE_DIR/dcef.sh"
