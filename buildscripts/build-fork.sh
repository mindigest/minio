#!/usr/bin/env bash
#
# Build the mindigest/minio fork: a stamped Linux binary plus the container
# image. This is the ONLY supported way to build this fork.
#
# Do not use `make build`, `make hotfix` or `make docker` here:
#   - make build   stamps the version from HEAD's *commit date*, so a fork
#                  commit makes the binary claim today's date instead of the
#                  upstream release it is based on.
#   - make hotfix  uses `sed 's#...\+...#'`, a GNU-only extension. On BSD/macOS
#                  sed the substitution silently no-ops, gen-ldflags.go then
#                  panics on the unparseable version, $(shell ...) swallows the
#                  panic, LDFLAGS ends up EMPTY -- and `go build` still exits 0,
#                  producing an unstamped, unstripped binary.
#   - make docker  tags into quay.io/minio (upstream's namespace) and builds a
#                  host-native binary, i.e. a macOS binary inside a Linux image.
#
# Usage:
#   buildscripts/build-fork.sh              # binary + image for linux/amd64
#   PLATFORM=linux/arm64 buildscripts/build-fork.sh
#   BINARY_ONLY=1 buildscripts/build-fork.sh
#
# Environment:
#   PLATFORM     target platform            (default linux/amd64)
#   REPO         image repository           (default mindigest/minio)
#   GOTOOLCHAIN  Go toolchain to build with (default: the go.mod directive)
#   BINARY_ONLY  set to 1 to skip the image build
#
set -euo pipefail

cd "$(dirname "$0")/.."

PLATFORM=${PLATFORM:-linux/amd64}
REPO=${REPO:-mindigest/minio}
TARGET_OS=${PLATFORM%%/*}
TARGET_ARCH=${PLATFORM##*/}

# Pin the compiler to what go.mod declares rather than whatever is installed:
# the fork exists to carry security fixes, and building it with a toolchain
# upstream never tested this tree against undoes some of that assurance.
if [ -z "${GOTOOLCHAIN:-}" ]; then
	GOTOOLCHAIN=$(awk '/^toolchain /{print $2}' go.mod)
	if [ -z "$GOTOOLCHAIN" ]; then
		echo "FATAL: no toolchain directive in go.mod; set GOTOOLCHAIN explicitly" >&2
		exit 1
	fi
fi
export GOTOOLCHAIN

BASE_TAG=$(git describe --tags --abbrev=0)
SHA=$(git rev-parse --short HEAD)
COMMIT_DATE=$(git log -1 --format=%cI)

# gen-ldflags.go wants 2025-10-15T17:29:55Z, not RELEASE.2025-10-15T17-29-55Z.
# `sed -E` is portable across BSD and GNU; the Makefile's `\+` form is not.
VERSION_ARG=$(printf '%s' "$BASE_TAG" |
	sed -E 's/^RELEASE\.([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2})-([0-9]{2})-([0-9]{2})Z$/\1-\2-\3T\4:\5:\6Z/')
if [ "$VERSION_ARG" = "$BASE_TAG" ]; then
	echo "FATAL: could not derive a version from tag '$BASE_TAG'" >&2
	exit 1
fi

MINIO_VERSION="${BASE_TAG}.hotfix.${SHA}"

# gen-ldflags.go panics rather than exiting non-zero on bad input, so check the
# output is non-empty instead of trusting the exit status.
LDFLAGS=$(MINIO_RELEASE=RELEASE MINIO_HOTFIX="hotfix.${SHA}" \
	go run buildscripts/gen-ldflags.go "$VERSION_ARG")
if [ -z "$LDFLAGS" ]; then
	echo "FATAL: gen-ldflags.go produced no LDFLAGS -- refusing to ship an unstamped binary" >&2
	exit 1
fi
case "$LDFLAGS" in
*"cmd.ReleaseTag=${MINIO_VERSION}"*) ;;
*)
	echo "FATAL: LDFLAGS does not carry ReleaseTag=${MINIO_VERSION}" >&2
	echo "       got: $LDFLAGS" >&2
	exit 1
	;;
esac

echo "==> version   ${MINIO_VERSION}"
echo "==> platform  ${PLATFORM}"
echo "==> toolchain ${GOTOOLCHAIN}"

echo "==> building ./minio"
CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" \
	go build -tags kqueue -trimpath --ldflags "$LDFLAGS" -o ./minio

# The Go toolchain records the VCS state in the binary. Refuse to ship one
# built from a dirty tree: the whole provenance story rests on this.
if go version -m ./minio | grep -q 'vcs.modified=true'; then
	echo "FATAL: built from a modified working tree (vcs.modified=true)" >&2
	exit 1
fi
go version -m ./minio | grep -E 'vcs\.(revision|modified)|GOARCH|GOOS' | sed 's/^/    /'

if [ "${BINARY_ONLY:-}" = "1" ]; then
	echo "==> BINARY_ONLY=1, skipping image build"
	exit 0
fi

# Tag with the exact version string the binary reports, so `minio --version`
# inside a container always names an image tag that still exists. The two
# moving tags are conveniences and get repointed on every build.
IMAGE_IMMUTABLE="${REPO}:${MINIO_VERSION}"
IMAGE_MOVING="${REPO}:${BASE_TAG}-console1.7.6"
IMAGE_LATEST="${REPO}:latest"

echo "==> building ${IMAGE_IMMUTABLE}"
docker buildx build --platform "$PLATFORM" --load \
	--build-arg MINIO_VERSION="$MINIO_VERSION" \
	--build-arg VCS_REF="$(git rev-parse HEAD)" \
	--build-arg BUILD_DATE="$COMMIT_DATE" \
	-t "$IMAGE_IMMUTABLE" \
	-t "$IMAGE_MOVING" \
	-t "$IMAGE_LATEST" \
	-f Dockerfile .

echo
echo "built:"
echo "  $IMAGE_IMMUTABLE   (immutable)"
echo "  $IMAGE_MOVING      (moving)"
echo "  $IMAGE_LATEST      (moving)"
echo
echo "push with:"
echo "  docker push $IMAGE_IMMUTABLE && docker push $IMAGE_MOVING && docker push $IMAGE_LATEST"
