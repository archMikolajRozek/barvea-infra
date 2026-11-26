# BARVEA — obraz MinIO budowany z WŁASNEJ kopii binarki (26.11.2026: dl.min.io = 410 Gone,
# Docker Hub minio/minio usunięty, quay.io puste — MinIO przestało publicznie dystrybuować
# binaria i obrazy). Źródło binarki: prod VM 101 /usr/local/bin/minio
# (RELEASE.2025-09-07T16-13-09Z) → ~/barvea-assets/minio.<RELEASE> (+ restic).
# Build (build-release-bundle.sh): docker build --build-arg MINIO_BIN=minio.<RELEASE> -t minio/minio:<RELEASE> images/minio
# Kompatybilny z compose dedyka: `command: server /data`, healthcheck curl :9000/minio/health/live.
FROM alpine:3.20
ARG MINIO_BIN=minio
RUN apk add --no-cache ca-certificates curl && addgroup -S minio && adduser -S -G minio -h /data minio
COPY ${MINIO_BIN} /usr/bin/minio
RUN chmod 755 /usr/bin/minio && mkdir -p /data && chown minio:minio /data
VOLUME ["/data"]
EXPOSE 9000 9001
USER minio
ENTRYPOINT ["/usr/bin/minio"]
CMD ["server", "/data"]
