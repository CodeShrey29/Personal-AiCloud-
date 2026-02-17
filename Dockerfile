FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# ── Copy build script ──
COPY build.sh /build/build.sh
RUN chmod +x /build/build.sh

# ── Copy seafile-server source ──
COPY Intelligent-cloud-core /build/seafile-server

# ── Run the build (compile libsearpc, seafile-server, Go fileserver) ──
WORKDIR /build
RUN ./build.sh build /build/seafile-server

# ────────────────────────────────────────────────────────────
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1

# ── Copy build script to runtime for setup commands ──
COPY build.sh /tmp/build.sh
RUN chmod +x /tmp/build.sh

# ── Install runtime dependencies via build.sh ──
RUN /tmp/build.sh install-runtime

# ── Copy built binaries and libraries ──
COPY --from=builder /built-libs/ /usr/lib/
COPY --from=builder /usr/bin/seaf-server /usr/bin/
COPY --from=builder /usr/bin/seafile-controller /usr/bin/
COPY --from=builder /usr/bin/fileserver /usr/bin/

# ── Copy ALL Python packages (seaserv, seafile, pysearpc) ──
COPY --from=builder /pypackages/ /usr/lib/python3/dist-packages/
RUN ldconfig

# ── Extra Python dependencies ──
COPY requirements.txt /tmp/extra-requirements.txt

# ── Copy seahub (Intelligent-cloud-web-end) ──
COPY Intelligent-cloud-web-end /opt/seahub
WORKDIR /opt/seahub

# ── Install all Python deps via build.sh ──
RUN /tmp/build.sh setup-seahub /tmp/extra-requirements.txt /opt/seahub/requirements.txt

# ── Copy SQL init scripts ──
COPY Intelligent-cloud-core/scripts/sql /opt/sql

# ── Data directories ──
RUN mkdir -p /data/seafile-data /data/ccnet /data/conf /data/logs /data/pids

# ── Copy SSL cert for MySQL ──
COPY ca.pem /etc/ssl/mysql/ca.pem

# ── Copy entrypoint ──
COPY docker-entrypoint.sh /entrypoint.sh
RUN dos2unix /entrypoint.sh 2>/dev/null || true
RUN chmod +x /entrypoint.sh

# ── Cleanup ──
RUN rm -f /tmp/build.sh

EXPOSE 8000

CMD ["/entrypoint.sh"]
