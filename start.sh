#!/usr/bin/env bash
# start.sh — Start script for Render.com native deployment (no Docker, no nginx)
# Render proxies HTTPS traffic directly to $PORT, so gunicorn serves on $PORT.
set -e

TOPDIR=/data
APP_ROOT="${APP_ROOT:-${RENDER_PROJECT_ROOT:-$(cd "$(dirname "$0")"/.. && pwd)}}"
INSTALL_DIR="${INSTALL_DIR:-$APP_ROOT/.cloudai}"
SEAHUB_DIR="${SEAHUB_DIR:-$APP_ROOT/.seahub}"
SQL_DIR="${SQL_DIR:-$APP_ROOT/.sql}"
SSL_CA_PATH="${SSL_CA_PATH:-$INSTALL_DIR/certs/ca.pem}"
PORT=${PORT:-8000}
HOSTNAME="${RENDER_EXTERNAL_HOSTNAME:-localhost}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-seafile}"
DB_PASS="${DB_PASS:-}"
DB_CCNET="${DB_NAME_CCNET:-ccnet_db}"
DB_SEAFILE="${DB_NAME_SEAFILE:-seafile_db}"
DB_SEAHUB="${DB_NAME_SEAHUB:-seahub_db}"

# ── Environment variables for seafile ──
export CCNET_CONF_DIR=$TOPDIR/ccnet
export SEAFILE_CONF_DIR=$TOPDIR/seafile-data
export SEAFILE_CENTRAL_CONF_DIR=$TOPDIR/conf
export SEAFILE_RPC_PIPE_PATH=$TOPDIR/seafile-data
export SEAFILE_LOG_TO_STDOUT=true
export SQL_DIR
export SSL_CA_PATH

# Add binaries and libraries to PATH/LD_LIBRARY_PATH
export PATH="$INSTALL_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"

# Add Python packages (pysearpc, seafile, seaserv) to PYTHONPATH
export PYTHONPATH="$INSTALL_DIR/pypackages:$SEAHUB_DIR:$SEAHUB_DIR/thirdpart:${PYTHONPATH:-}"

if [ "${START_VALIDATE_ONLY:-0}" = "1" ]; then
    echo "Validation-only mode enabled. Running startup preflight checks..."
    test -x "$INSTALL_DIR/bin/seaf-server"
    test -x "$INSTALL_DIR/bin/fileserver"
    test -f "$APP_ROOT/wsgi_proxy.py"
    test -d "$SEAHUB_DIR"
    if ! command -v gunicorn >/dev/null; then
        echo "Validation note: gunicorn is not available in current PATH."
        echo "This is expected only if pip dependencies were not installed in this environment."
    fi
    echo "Validation preflight passed."
    exit 0
fi

# ── Cleanup on exit ──
cleanup() {
    echo "Shutting down..."
    kill $(cat $TOPDIR/pids/seafile.pid 2>/dev/null) 2>/dev/null || true
    kill $(cat $TOPDIR/pids/fileserver.pid 2>/dev/null) 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── First-time setup ────────────────────────────────────────
if [ ! -f "$TOPDIR/conf/seafile.conf" ]; then
    echo "=== First-time Cloudai setup ==="

    mkdir -p $TOPDIR/ccnet $TOPDIR/seafile-data $TOPDIR/conf $TOPDIR/logs $TOPDIR/pids

    # ── Initialize DB schemas using Python (no mysql CLI needed) ──
    echo "Initializing database schemas..."
    python3 -c "
import MySQLdb
import os

host = os.environ.get('DB_HOST', '127.0.0.1')
port = int(os.environ.get('DB_PORT', '3306'))
user = os.environ.get('DB_USER', 'seafile')
passwd = os.environ.get('DB_PASS', '')
ssl_ca = os.environ.get('SSL_CA_PATH', '')

ssl_settings = {'ca': ssl_ca} if os.path.exists(ssl_ca) else None

for db_name, sql_file in [
    (os.environ.get('DB_NAME_CCNET', 'ccnet_db'), os.path.join(os.environ.get('SQL_DIR', ''), 'mysql/ccnet.sql')),
    (os.environ.get('DB_NAME_SEAFILE', 'seafile_db'), os.path.join(os.environ.get('SQL_DIR', ''), 'mysql/seafile.sql')),
]:
    try:
        if not os.path.exists(sql_file):
            print(f'  Schema note for {db_name}: missing SQL file at {sql_file}')
            continue
        conn = MySQLdb.connect(host=host, port=port, user=user, passwd=passwd,
                               db=db_name, charset='utf8', ssl=ssl_settings)
        cursor = conn.cursor()
        with open(sql_file, 'r') as f:
            sql = f.read()
        for statement in sql.split(';'):
            statement = statement.strip()
            if statement:
                try:
                    cursor.execute(statement)
                except Exception as e:
                    pass  # Table may already exist
        conn.commit()
        cursor.close()
        conn.close()
        print(f'  ✓ {db_name} schema initialized')
    except Exception as e:
        print(f'  Schema note for {db_name}: {e}')
" 2>&1

    # ── ccnet.conf ──
    cat > $TOPDIR/conf/ccnet.conf << EOF
[General]
SERVICE_URL = https://${HOSTNAME}

[Database]
ENGINE = mysql
HOST = ${DB_HOST}
PORT = ${DB_PORT}
USER = ${DB_USER}
PASSWD = ${DB_PASS}
DB = ${DB_CCNET}
CONNECTION_CHARSET = utf8
USE_SSL = true
SKIP_VERIFY = false
CA_PATH = ${SSL_CA_PATH}
EOF

    # ── seafile.conf ──
    cat > $TOPDIR/conf/seafile.conf << EOF
[fileserver]
port = 8082
host = 0.0.0.0

[database]
type = mysql
host = ${DB_HOST}
port = ${DB_PORT}
user = ${DB_USER}
password = ${DB_PASS}
db_name = ${DB_SEAFILE}
connection_charset = utf8
use_ssl = true
skip_verify = false
ca_path = ${SSL_CA_PATH}
EOF

    # ── seahub_settings.py ──
    SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    JWT_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    cat > $TOPDIR/conf/seahub_settings.py << PYEOF
SECRET_KEY = '${SECRET}'
JWT_PRIVATE_KEY = '${JWT_KEY}'

SERVICE_URL = 'https://${HOSTNAME}'
FILE_SERVER_ROOT = 'https://${HOSTNAME}/seafhttp'

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': '${DB_SEAHUB}',
        'USER': '${DB_USER}',
        'PASSWORD': '${DB_PASS}',
        'HOST': '${DB_HOST}',
        'PORT': '${DB_PORT}',
        'OPTIONS': {
            'charset': 'utf8mb4',
            'ssl': {'ca': '${SSL_CA_PATH}'},
        },
    }
}

CSRF_TRUSTED_ORIGINS = ['https://${HOSTNAME}']
ALLOWED_HOSTS = ['*']

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.locmem.LocMemCache',
    },
}

TIME_ZONE = 'UTC'
PYEOF

    # ── Create seafile-data structure ──
    echo "{ \"version\": 1 }" > $TOPDIR/seafile-data/seafile.conf 2>/dev/null || true
    mkdir -p $TOPDIR/seafile-data/storage/blocks
    mkdir -p $TOPDIR/seafile-data/storage/commits
    mkdir -p $TOPDIR/seafile-data/storage/fs
    mkdir -p $TOPDIR/seafile-data/tmpfiles
    mkdir -p $TOPDIR/seafile-data/httptemp

    # ── Create admin user ──
    ADMIN_EMAIL="${SEAFILE_ADMIN_EMAIL:-admin@seafile.local}"
    ADMIN_PASS="${SEAFILE_ADMIN_PASSWORD:-Changeme123!}"
    python3 -c "
import os
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'seahub.settings')
import django
django.setup()
from seahub.base.accounts import User
try:
    u = User.objects.create_user('${ADMIN_EMAIL}', is_staff=True, is_active=True)
    u.set_password('${ADMIN_PASS}')
    u.save()
    print('Admin created: ${ADMIN_EMAIL}')
except Exception as e:
    print(f'Admin note: {e}')
" 2>&1

    echo "=== Setup complete ==="
fi

# ── Export DB env vars for Go fileserver ──
export SEAFILE_MYSQL_DB_USER="${DB_USER:-seafile}"
export SEAFILE_MYSQL_DB_PASSWORD="${DB_PASS:-}"
export SEAFILE_MYSQL_DB_HOST="${DB_HOST:-127.0.0.1}"
export SEAFILE_MYSQL_DB_CCNET_DB_NAME="${DB_NAME_CCNET:-ccnet_db}"
export SEAFILE_MYSQL_DB_SEAFILE_DB_NAME="${DB_NAME_SEAFILE:-seafile_db}"
export JWT_PRIVATE_KEY=$(grep JWT_PRIVATE_KEY $TOPDIR/conf/seahub_settings.py | head -1 | cut -d"'" -f2)

# ── Run database migrations ──
echo "Running database migrations..."
export DJANGO_SETTINGS_MODULE=seahub.settings
cd $SEAHUB_DIR
python3 manage.py migrate --noinput 2>&1 || echo "Migration note: will retry on next boot"

# ── Start seaf-server (C daemon, background) ──
echo "Starting seaf-server..."
seaf-server -c $TOPDIR/ccnet -d $TOPDIR/seafile-data -F $TOPDIR/conf -f -l $TOPDIR/logs/seafile.log -P $TOPDIR/pids/seafile.pid -p $TOPDIR/seafile-data &
sleep 2

# ── Start Go fileserver (background) ──
echo "Starting fileserver..."
fileserver -F $TOPDIR/conf -d $TOPDIR/seafile-data -l $TOPDIR/logs/fileserver.log -p $TOPDIR/seafile-data -P $TOPDIR/pids/fileserver.pid &
sleep 1

# ── Start seahub (gunicorn, foreground) ──
# Render expects the web process to listen on $PORT
# No nginx needed — Render handles HTTPS termination and routing
echo "☁️  Starting Cloudai (gunicorn on port $PORT)..."
# Use the proxy WSGI app that routes /seafhttp to fileserver:8082
# and everything else to seahub (Django)
cd $SEAHUB_DIR
exec gunicorn wsgi_proxy:application \
    --bind "0.0.0.0:${PORT}" \
    --workers 3 \
    --timeout 1200 \
    --limit-request-line 8190 \
    --preload \
    --chdir "$APP_ROOT"
