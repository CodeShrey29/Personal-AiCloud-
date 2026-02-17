FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# ── Build dependencies ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential autoconf automake libtool pkg-config \
    python3 python3-dev python3-pip python3-setuptools \
    libglib2.0-dev libglib2.0-dev-bin libssl-dev libevent-dev libcurl4-openssl-dev \
    libsqlite3-dev libjansson-dev libarchive-dev \
    uuid-dev intltool libfuse-dev \
    wget curl git golang-go ca-certificates \
    default-libmysqlclient-dev libldap2-dev libsasl2-dev \
    libjpeg-dev zlib1g-dev libcairo2-dev libgirepository1.0-dev \
    valac cmake libzdb-dev \
    libhiredis-dev libjwt-dev libargon2-dev \
    dos2unix \
    && rm -rf /var/lib/apt/lists/*

# ── Build libsearpc (required dependency) ──
WORKDIR /build
RUN git clone --depth 1 https://github.com/haiwen/libsearpc.git \
    && cd libsearpc \
    && ./autogen.sh \
    && ./configure --prefix=/usr \
    && make -j$(nproc) \
    && make install \
    && ldconfig

# ── Build seafile-server core (Intelligent-cloud-core) ──
# ccnet is merged into seafile-server in this version — no separate ccnet-server build needed
COPY Intelligent-cloud-core /build/seafile-server
WORKDIR /build/seafile-server

# Fix Windows CRLF line endings and make scripts executable
RUN find . -type f \( -name "*.sh" -o -name "*.ac" -o -name "*.am" -o -name "*.in" \
    -o -name "*.py" -o -name "*.m4" -o -name "*.vala" -o -name "*.c" -o -name "*.h" \
    -o -name "*.pc.in" -o -name "Makefile*" -o -name "configure*" \) -exec dos2unix {} + \
    && chmod +x autogen.sh

RUN ./autogen.sh \
    && ./configure --prefix=/usr \
       --enable-python \
       --disable-fuse \
       --disable-httpserver \
       CFLAGS="-Wno-deprecated-declarations" \
    && make -j$(nproc) \
    && make install

# ── Build Go fileserver ──
WORKDIR /build/seafile-server/fileserver
RUN go build -o /usr/bin/fileserver .

# ────────────────────────────────────────────────────────────
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1

# ── Runtime dependencies ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-setuptools python3-dev \
    pkg-config build-essential \
    default-libmysqlclient-dev libldap2-dev libsasl2-dev \
    libglib2.0-0 libssl3 libevent-2.1-7 libcurl4 \
    libsqlite3-0 libjansson4 libarchive13 \
    libmysqlclient21 libuuid1 \
    libjpeg-turbo8 zlib1g libcairo2 \
    libldap-2.5-0 libsasl2-2 \
    libhiredis0.14 libjwt0 libargon2-1 \
    procps sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# ── Copy built binaries and libraries ──
COPY --from=builder /usr/lib/libsearpc* /usr/lib/
COPY --from=builder /usr/lib/libseafile* /usr/lib/
COPY --from=builder /usr/lib/python3*/dist-packages/ /usr/lib/python3/dist-packages/
COPY --from=builder /usr/bin/seaf-server /usr/bin/
COPY --from=builder /usr/bin/seafile-controller /usr/bin/
COPY --from=builder /usr/bin/fileserver /usr/bin/
RUN ldconfig

# ── Extra Python dependencies ──
COPY requirements.txt /tmp/extra-requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/extra-requirements.txt

# ── Copy seahub (Intelligent-cloud-web-end) ──
COPY Intelligent-cloud-web-end /opt/seahub
WORKDIR /opt/seahub

# ── Python dependencies for seahub ──
# Ensure mysqlclient can build even when pkg-config cannot auto-detect lib name.
RUN export MYSQLCLIENT_CFLAGS="$(mysql_config --cflags)" \
    && export MYSQLCLIENT_LDFLAGS="$(mysql_config --libs)" \
    && pip3 install --no-cache-dir -r requirements.txt \
    && pip3 install --no-cache-dir future pycryptodome

# ── Copy SQL init scripts ──
COPY Intelligent-cloud-core/scripts/sql /opt/sql

# ── Data directories ──
RUN mkdir -p /data/seafile-data /data/ccnet /data/conf /data/logs /data/pids

# ── Copy SSL cert for MySQL ──
COPY ca.pem /etc/ssl/mysql/ca.pem

# ── Copy entrypoint ──
COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

CMD ["/entrypoint.sh"]
