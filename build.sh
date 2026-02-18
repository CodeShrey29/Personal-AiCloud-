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

apt_update_safe() {
  # Keep apt resilient in restricted build environments (read-only apt dirs, etc.)
  if touch /var/lib/apt/lists/.cloudai_rw_test 2>/dev/null; then
    rm -f /var/lib/apt/lists/.cloudai_rw_test
    mkdir -p /var/lib/apt/lists/partial
    chown _apt:root /var/lib/apt/lists/partial 2>/dev/null || true
    chmod 700 /var/lib/apt/lists/partial 2>/dev/null || true
    apt-get update
    return
  fi

  local state_dir="/tmp/apt-state/lists"
  local cache_dir="/tmp/apt-cache/archives"
  mkdir -p "$state_dir/partial" "$cache_dir/partial"
  apt-get \
    -o Dir::State::lists="$state_dir" \
    -o Dir::Cache::archives="$cache_dir" \
    update
}

apt_install_safe() {
  if touch /var/lib/apt/lists/.cloudai_rw_test 2>/dev/null; then
    rm -f /var/lib/apt/lists/.cloudai_rw_test
    apt-get install -y --no-install-recommends "$@"
    return
  fi

  local state_dir="/tmp/apt-state/lists"
  local cache_dir="/tmp/apt-cache/archives"
  mkdir -p "$state_dir/partial" "$cache_dir/partial"
  apt-get \
    -o Dir::State::lists="$state_dir" \
    -o Dir::Cache::archives="$cache_dir" \
    install -y --no-install-recommends "$@"
}

download_release_asset() {
  local output_file="$1"

  # Optional local override for environments where GitHub release download is blocked.
  local local_tarball="${LOCAL_BINARIES_TARBALL:-}"
  if [ -n "$local_tarball" ]; then
    if [ ! -f "$local_tarball" ]; then
      echo "  ✗ LOCAL_BINARIES_TARBALL is set but file does not exist: $local_tarball"
      return 1
    fi
    echo "  Using local binaries tarball: $local_tarball"
    cp "$local_tarball" "$output_file"
    return 0
  fi

  # First try the public release URL (works for public repositories).
  if curl -fL --retry 3 --retry-delay 2 "$DOWNLOAD_URL" -o "$output_file"; then
    return 0
  fi

  # Fallback for private repositories: use a GitHub token if provided.
  local gh_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -z "$gh_token" ]; then
    echo "  ✗ Failed to download binaries from public release URL."
    echo "    If this repository is private OR outbound GitHub access is restricted, set GITHUB_TOKEN (or GH_TOKEN)."
    echo "    Alternatively, provide LOCAL_BINARIES_TARBALL=/path/to/cloudai-binaries.tar.gz"
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

# Install native build dependencies needed by some pyproject.toml packages
# (for example: python-ldap, mysqlclient, cffi/cairosvg stack) when wheels
# are unavailable for the target platform.
if command -v apt-get >/dev/null 2>&1; then
  echo "  Detected apt-get; installing native build dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  if ! apt_update_safe; then
    echo "  ⚠ apt-get update failed (network/proxy/repo issue). Continuing; build may still succeed if deps are preinstalled."
  fi

  if ! apt_install_safe \
    build-essential \
    pkg-config \
    python3-dev \
    cargo \
    rustc \
    default-libmysqlclient-dev \
    libldap2-dev \
    libsasl2-dev \
    libssl-dev \
    libffi-dev \
    libxml2-dev \
    libxmlsec1-dev \
    libxmlsec1-openssl \
    libcairo2-dev \
    libjpeg-dev \
    zlib1g-dev; then
    echo "  ⚠ apt-get install failed (network/proxy/repo issue). Continuing; pip install will determine if deps are sufficient."
  fi

  rm -rf /var/lib/apt/lists/* /tmp/apt-state /tmp/apt-cache
else
  echo "  ⚠ apt-get not found; assuming build dependencies are preinstalled"
fi

pip install --upgrade pip setuptools wheel

# All Python dependencies (consolidated in root requirements.txt)
pip install --no-cache-dir --prefer-binary -r requirements.txt
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
