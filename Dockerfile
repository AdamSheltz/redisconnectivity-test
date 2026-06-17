# redis-connectivity-test image
#
# Minimal Debian-slim base (not Alpine) chosen deliberately: redis-tools and
# common DNS utilities are well-packaged and glibc-based, and `nc` behaves
# more predictably here than the BusyBox `nc` shipped in Alpine (which has
# weaker -w timeout semantics and was a real cause of hangs during testing).

FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    redis-tools \
    dnsutils \
    iputils-ping \
    netcat-openbsd \
    openssl \
    python3 \
    ca-certificates \
    coreutils \
    bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY redis-connectivity-test.sh /app/redis-connectivity-test.sh
RUN chmod +x /app/redis-connectivity-test.sh

# Runs as non-root by default; override with securityContext in the pod spec
RUN useradd -m -u 10001 testrunner
USER testrunner

ENTRYPOINT ["/app/redis-connectivity-test.sh"]
