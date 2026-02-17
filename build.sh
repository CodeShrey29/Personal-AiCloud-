#!/usr/bin/env bash
# build.sh — Build script for Render.com native deployment
# Downloads pre-built C/Go binaries and installs Python dependencies
set -e

echo "╔══════════════════════════════════════════════════╗"
echo "║      Cloudai — Render Native Build Script        ║"
echo "╚══════════════════════════════════════════════════╝"

REPO="CodeShrey29/Personal-AiCloud-"
TAG="build-latest"
TARBALL="cloudai-binaries.tar.gz"
APP_ROOT="${APP_ROOT:-${RENDER_PROJECT_ROOT:-$PWD}}"
INSTALL_DIR="${INSTALL_DIR:-$APP_ROOT/.cloudai}"
SEAHUB_DIR="${SEAHUB_DIR:-$APP_ROOT/.seahub}"
SQL_DIR="${SQL_DIR:-$APP_ROOT/.sql}"
SSL_CA_PATH="${SSL_CA_PATH:-$INSTALL_DIR/certs/ca.pem}"

# ── 1. Download pre-built binaries from GitHub Release ──
echo "=== [1/5] Downloading pre-built binaries ==="
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${TARBALL}"
echo "  URL: $DOWNLOAD_URL"
mkdir -p /tmp/cloudai-binaries

download_release_asset() {
  local output_file="$1"

  # First try the public release URL (works for public repositories).
  if curl -fL --retry 3 --retry-delay 2 "$DOWNLOAD_URL" -o "$output_file"; then
    return 0
  fi

  # Fallback for private repositories: use a GitHub token if provided.
  local gh_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -z "$gh_token" ]; then
    echo "  ✗ Failed to download binaries from public release URL."
    echo "    If this repository is private, set GITHUB_TOKEN (or GH_TOKEN) in your deploy environment."
    return 1
  fi

  echo "  Public download failed; retrying with GitHub API token authentication..."
  local releases_api="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
  local asset_url

  asset_url=$(curl -fsSL \
    -H "Authorization: Bearer ${gh_token}" \
    -H "Accept: application/vnd.github+json" \
    "$releases_api" | python -c "import json,sys; data=json.load(sys.stdin); print(next((a['url'] for a in data.get('assets', []) if a.get('name') == '${TARBALL}'), ''))")

  if [ -z "$asset_url" ]; then
    echo "  ✗ Release tag '${TAG}' found, but asset '${TARBALL}' was not present."
    return 1
  fi

  curl -fsSL \
    -H "Authorization: Bearer ${gh_token}" \
    -H "Accept: application/octet-stream" \
    "$asset_url" -o "$output_file"
}

download_release_asset "/tmp/${TARBALL}"
tar -xzf "/tmp/${TARBALL}" -C /tmp/cloudai-binaries
echo "  ✓ Binaries downloaded and extracted"

# ── 2. Install binaries and libraries ──
echo "=== [2/5] Installing binaries and libraries ==="
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$INSTALL_DIR/certs"

# Copy binaries
cp /tmp/cloudai-binaries/bin/* "$INSTALL_DIR/bin/"
chmod +x "$INSTALL_DIR/bin"/*

# Copy libraries
cp -a /tmp/cloudai-binaries/lib/* "$INSTALL_DIR/lib/" 2>/dev/null || true

# Copy Python packages (pysearpc, seafile, seaserv)
PYPACKAGES_DIR="$INSTALL_DIR/pypackages"
mkdir -p "$PYPACKAGES_DIR"
cp -r /tmp/cloudai-binaries/pypackages/* "$PYPACKAGES_DIR/" 2>/dev/null || true

# Also copy from source tree as extra fallback
cp -r Intelligent-cloud-core/python/seafile "$PYPACKAGES_DIR/" 2>/dev/null || true
cp -r Intelligent-cloud-core/python/seaserv "$PYPACKAGES_DIR/" 2>/dev/null || true

echo "  ✓ Binaries: $(ls $INSTALL_DIR/bin/)"
echo "  ✓ Libraries: $(ls $INSTALL_DIR/lib/ | head -5)"
echo "  ✓ Python packages: $(ls $PYPACKAGES_DIR/)"

# ── 3. Install seahub (web UI) ──
echo "=== [3/5] Setting up seahub ==="
mkdir -p "$SEAHUB_DIR"
cp -a Intelligent-cloud-web-end/. "$SEAHUB_DIR/"
echo "  ✓ Seahub copied to $SEAHUB_DIR"

# ── 4. Install Python dependencies ──
echo "=== [4/5] Installing Python dependencies ==="
pip install --upgrade pip setuptools wheel

# All Python dependencies (consolidated in root requirements.txt)
pip install --no-cache-dir -r requirements.txt
echo "  ✓ Python dependencies installed"

# ── 5. Setup directories and configs ──
echo "=== [5/5] Setting up directories ==="
mkdir -p /data/seafile-data/storage/blocks \
         /data/seafile-data/storage/commits \
         /data/seafile-data/storage/fs \
         /data/seafile-data/tmpfiles \
         /data/seafile-data/httptemp \
         /data/ccnet \
         /data/conf \
         /data/logs \
         /data/pids

# Copy WSGI proxy (routes /seafhttp to fileserver, everything else to seahub)
cp wsgi_proxy.py "$APP_ROOT/wsgi_proxy.py"

# Copy SQL scripts
mkdir -p "$SQL_DIR"
cp -a Intelligent-cloud-core/scripts/sql/. "$SQL_DIR/" 2>/dev/null || true

# Copy SSL cert for MySQL
cp ca.pem "$SSL_CA_PATH" 2>/dev/null || echo "  ⚠ ca.pem not found (set up SSL cert manually)"

# Copy start script
cp start.sh "$INSTALL_DIR/start.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/start.sh" 2>/dev/null || true

# Cleanup
rm -rf /tmp/cloudai-binaries /tmp/${TARBALL}
echo "  ✓ Setup complete"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║          Build complete! ✓                       ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Installed:"
echo "  Binaries: $INSTALL_DIR/bin/"
echo "  Libraries: $INSTALL_DIR/lib/"
echo "  Python pkgs: $PYPACKAGES_DIR/"
echo "  Seahub: $SEAHUB_DIR/"
echo "  SQL: $SQL_DIR/"
echo "  SSL CA: $SSL_CA_PATH"
