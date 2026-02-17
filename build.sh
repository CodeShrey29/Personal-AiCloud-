#!/usr/bin/env bash
# build.sh — Build script for Render.com native deployment
# Downloads pre-built C/Go binaries and installs Python dependencies
set -e

echo "╔══════════════════════════════════════════════════╗"
echo "║      Cloudai — Render Native Build Script        ║"
echo "╚══════════════════════════════════════════════════╝"

REPO="codeshrey29/personal-aicloud-"
TAG="build-latest"
TARBALL="cloudai-binaries.tar.gz"
INSTALL_DIR="/opt/cloudai"

# ── 1. Download pre-built binaries from GitHub Release ──
echo "=== [1/5] Downloading pre-built binaries ==="
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${TARBALL}"
echo "  URL: $DOWNLOAD_URL"
mkdir -p /tmp/cloudai-binaries
curl -fsSL "$DOWNLOAD_URL" -o "/tmp/${TARBALL}"
tar -xzf "/tmp/${TARBALL}" -C /tmp/cloudai-binaries
echo "  ✓ Binaries downloaded and extracted"

# ── 2. Install binaries and libraries ──
echo "=== [2/5] Installing binaries and libraries ==="
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/lib"

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
mkdir -p /opt/seahub
cp -a Intelligent-cloud-web-end/. /opt/seahub/
echo "  ✓ Seahub copied to /opt/seahub"

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
cp wsgi_proxy.py /opt/wsgi_proxy.py

# Copy SQL scripts
mkdir -p /opt/sql
cp -a Intelligent-cloud-core/scripts/sql/. /opt/sql/ 2>/dev/null || true

# Copy SSL cert for MySQL
mkdir -p /etc/ssl/mysql
cp ca.pem /etc/ssl/mysql/ca.pem 2>/dev/null || echo "  ⚠ ca.pem not found (set up SSL cert manually)"

# Copy start script
cp start.sh /opt/cloudai/start.sh 2>/dev/null || true
chmod +x /opt/cloudai/start.sh 2>/dev/null || true

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
echo "  Seahub: /opt/seahub/"
echo "  SQL: /opt/sql/"
