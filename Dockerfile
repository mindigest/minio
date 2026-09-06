# Container image for the mindigest/minio fork.
#
# This does NOT build from source: it layers a prebuilt Linux binary onto the
# upstream MinIO runtime image. Build it with buildscripts/build-fork.sh, which
# cross-compiles ./minio for the target platform and supplies the ARGs below.
# A bare `docker build .` only works if ./minio is already a Linux binary for
# the target platform, and it will leave the version labels as "unknown".
#
# The base is pinned by digest deliberately. minio/minio:latest floats, and
# upstream stopped publishing community images after RELEASE.2025-09-07T16-13-09Z
# (there is no minio/minio:RELEASE.2025-10-15T17-29-55Z on Docker Hub), so an
# unpinned base silently changes the userland from one rebuild to the next.
FROM minio/minio:RELEASE.2025-09-07T16-13-09Z@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e

ARG MINIO_VERSION=unknown
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

# These overwrite labels inherited from the base image. Without them the image
# advertises the base's release (RELEASE.2025-09-07T16-13-09Z), the base's
# commit, and "MinIO Inc" as vendor -- so CVE scanners, admission controllers,
# SBOM tooling and inventory systems all report the wrong version and credit
# the fork to upstream. That matters here specifically: this fork exists to
# carry two security-relevant fixes the 2025-09-07 build does not have.
LABEL name="mindigest/minio" \
      vendor="mindigest" \
      maintainer="mindigest" \
      version="${MINIO_VERSION}" \
      release="${MINIO_VERSION}" \
      vcs-ref="${VCS_REF}" \
      vcs-type="git" \
      summary="MinIO ${MINIO_VERSION} with the full web console (minio/console v1.7.6)." \
      description="Fork of minio/minio at RELEASE.2025-10-15T17-29-55Z with github.com/minio/console pinned back to v1.7.6, the last release carrying the full web console." \
      org.opencontainers.image.title="mindigest/minio" \
      org.opencontainers.image.description="MinIO RELEASE.2025-10-15T17-29-55Z with the full web console (minio/console v1.7.6)." \
      org.opencontainers.image.version="${MINIO_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/mindigest/minio" \
      org.opencontainers.image.url="https://github.com/mindigest/minio" \
      org.opencontainers.image.vendor="mindigest" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.base.name="docker.io/minio/minio:RELEASE.2025-09-07T16-13-09Z" \
      org.opencontainers.image.base.digest="sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e"

# --chmod replaces upstream's `RUN chmod -R 777 /usr/bin`, which made every
# binary in /usr/bin world-writable (anything with code execution in the
# container could overwrite /usr/bin/minio and persist) and, because it
# rewrote the whole directory, copied the shadowed base minio binary into a
# second ~150MB layer that ships on every pull and can never be reached.
COPY --chmod=0755 ./minio /usr/bin/minio
COPY --chmod=0755 dockerscripts/docker-entrypoint.sh /usr/bin/docker-entrypoint.sh

# 9000 = S3 API, 9001 = web console. The base only declares 9000, and the
# console is this fork's entire reason for existing.
EXPOSE 9000 9001

ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]

VOLUME ["/data"]

CMD ["minio"]
