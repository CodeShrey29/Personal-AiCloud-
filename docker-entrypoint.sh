#!/bin/bash
set -e

TOPDIR=/data
SEAHUB_DIR=/opt/seahub
PORT=${PORT:-8000}
HOSTNAME="${RENDER_EXTERNAL_HOSTNAME:-localhost}"

export CCNET_CONF_DIR=$TOPDIR/ccnet
export SEAFILE_CONF_DIR=$TOPDIR/seafile-data
export SEAFILE_CENTRAL_CONF_DIR=$TOPDIR/conf
export SEAFILE_LOG_TO_STDOUT=true
export PYTHONPATH=$SEAHUB_DIR:$SEAHUB_DIR/thirdpart:/usr/lib/python3/dist-packages:$PYTHONPATH

# ── First-time setup ────────────────────────────────────────
if [ ! -f "$TOPDIR/conf/seafile.conf" ]; then
    echo "=== First-time Seafile setup ==="

    mkdir -p $TOPDIR/ccnet $TOPDIR/seafile-data $TOPDIR/conf $TOPDIR/logs $TOPDIR/pids

    # DB settings from environment
    DB_HOST="${DB_HOST:-127.0.0.1}"
    DB_PORT="${DB_PORT:-3306}"
    DB_USER="${DB_USER:-seafile}"
    DB_PASS="${DB_PASS:-}"
    DB_CCNET="${DB_NAME_CCNET:-ccnet_db}"
    DB_SEAFILE="${DB_NAME_SEAFILE:-seafile_db}"
    DB_SEAHUB="${DB_NAME_SEAHUB:-seahub_db}"

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
        'OPTIONS': {'charset': 'utf8mb4'},
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

    # ── gunicorn.conf.py ──
    cat > $TOPDIR/conf/gunicorn.conf.py << PYEOF
bind = "0.0.0.0:${PORT}"
workers = 3
timeout = 1200
limit_request_line = 8190
PYEOF

    # ── Create seafile-data structure ──
    echo "{ \"version\": 1 }" > $TOPDIR/seafile-data/seafile.conf 2>/dev/null || true
    mkdir -p $TOPDIR/seafile-data/storage/blocks
    mkdir -p $TOPDIR/seafile-data/storage/commits
    mkdir -p $TOPDIR/seafile-data/storage/fs
    mkdir -p $TOPDIR/seafile-data/tmpfiles
    mkdir -p $TOPDIR/seafile-data/httptemp

    # ── Run seahub migrations ──
    echo "Running database migrations..."
    export DJANGO_SETTINGS_MODULE=seahub.settings
    cd $SEAHUB_DIR
    python3 manage.py migrate --noinput 2>&1 || echo "Migration note: will retry"

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

# ── Always update gunicorn port (Render may change it) ──
cat > $TOPDIR/conf/gunicorn.conf.py << PYEOF
bind = "0.0.0.0:${PORT}"
workers = 3
timeout = 1200
limit_request_line = 8190
PYEOF

# ── Export DB env vars for Go fileserver ──
export SEAFILE_MYSQL_DB_USER="${DB_USER:-seafile}"
export SEAFILE_MYSQL_DB_PASSWORD="${DB_PASS:-}"
export SEAFILE_MYSQL_DB_HOST="${DB_HOST:-127.0.0.1}"
export SEAFILE_MYSQL_DB_CCNET_DB_NAME="${DB_NAME_CCNET:-ccnet_db}"
export SEAFILE_MYSQL_DB_SEAFILE_DB_NAME="${DB_NAME_SEAFILE:-seafile_db}"
export JWT_PRIVATE_KEY=$(grep JWT_PRIVATE_KEY $TOPDIR/conf/seahub_settings.py | head -1 | cut -d"'" -f2)

# ── Start seaf-server (C daemon, background) ──
echo "Starting seaf-server..."
seaf-server -c $TOPDIR/ccnet -d $TOPDIR/seafile-data -F $TOPDIR/conf -l $TOPDIR/logs/seafile.log -P $TOPDIR/pids/seafile.pid &
sleep 2

# ── Start Go fileserver (background) ──
echo "Starting fileserver..."
fileserver -F $TOPDIR/conf -d $TOPDIR/seafile-data -l $TOPDIR/logs/fileserver.log -p $TOPDIR/ccnet/seafile.sock -P $TOPDIR/pids/fileserver.pid &
sleep 1

# ── Start seahub (gunicorn, FOREGROUND) ──
echo "☁️  Starting Cloudai on port $PORT ..."
cd $SEAHUB_DIR
exec gunicorn seahub.wsgi:application \
    -c $TOPDIR/conf/gunicorn.conf.py \
    --preload
