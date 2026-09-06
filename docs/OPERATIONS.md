# Operating mindigest/minio

Day-to-day commands for the [mindigest/minio](https://github.com/mindigest/minio) fork.
For what the fork is and why it exists, see [FORK.md](../FORK.md).

Everything here is specific to this fork. Upstream MinIO instructions found elsewhere may
not apply — in particular `go install github.com/minio/minio@latest` builds *upstream*, which
ships the stripped-down object-browser instead of the full web console.

## Image tags

| Tag | Mutability | Use for |
| --- | --- | --- |
| `mindigest/minio:RELEASE.<base>.hotfix.<sha>` | immutable | **production** — byte-identical to what `minio --version` reports |
| `mindigest/minio:RELEASE.<base>-console1.7.6` | moving | tracking the latest build of this base release |
| `mindigest/minio:latest` | moving | development only |

Pin the immutable tag in production. The moving tags are repointed on every build, so a
container restart can silently change the binary underneath you.

Images are **`linux/amd64` only**. On Apple Silicon add `--platform linux/amd64` (runs under
emulation); on amd64 hosts omit it. Build with `PLATFORM=linux/arm64` if you need arm64.

## Building

From the repository root:

```sh
buildscripts/build-fork.sh
```

Cross-compiles the Linux binary with correct version stamping and builds the image with all
three tags. This is the only supported build path — see
[FORK.md § Do not use the upstream build paths](../FORK.md#do-not-use-the-upstream-build-paths)
for why `make build`, `make hotfix` and `make docker` are traps here.

```sh
BINARY_ONLY=1 buildscripts/build-fork.sh        # binary only, skip the image
PLATFORM=linux/arm64 buildscripts/build-fork.sh # different target platform
REPO=myorg/minio buildscripts/build-fork.sh     # different image repository
```

`GOTOOLCHAIN` defaults to the `toolchain` directive in `go.mod`; override it only
deliberately.

The build fails rather than producing a wrong artifact when `github.com/minio/console` is not
the pinned version, when `LDFLAGS` comes out empty or wrong, when the working tree is dirty,
or when the base version cannot be derived from the nearest upstream tag.

## Publishing

```sh
docker push mindigest/minio:RELEASE.<base>.hotfix.<sha>
docker push mindigest/minio:RELEASE.<base>-console1.7.6
docker push mindigest/minio:latest
```

Tag the source commit to match the image:

```sh
git tag -a RELEASE.<base>.hotfix.<sha> -m "console pinned to v1.7.6" <sha>
git push origin RELEASE.<base>.hotfix.<sha>
```

## Running

The image's entrypoint prepends `minio`, so pass `server ...` directly. Port 9000 is the S3
API and 9001 the web console; both are declared `EXPOSE`d.

### Single drive — development

```sh
docker run -d --name minio \
  -p 9000:9000 -p 9001:9001 \
  -v ~/minio-data:/data \
  mindigest/minio:latest \
  server /data --console-address ":9001"
```

Starts with the default `minioadmin:minioadmin` credentials and warns about them. Fine for a
throwaway; never for anything reachable.

### Four drives, erasure coded — closer to production

```sh
docker run -d --name minio \
  -p 9000:9000 -p 9001:9001 \
  -v ~/minio-data:/data \
  mindigest/minio:latest \
  server /data/d{1...4} --console-address ":9001"
```

Four drives in one container gives `EC:2` (data 2 / parity 2). Note this is the `data ==
parity` case that upstream fix `64f5c6103` addresses — it is in this build.

### Production

```sh
docker run -d --name minio \
  --restart unless-stopped \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
  -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
  -v /mnt/disk1:/data/d1 \
  -v /mnt/disk2:/data/d2 \
  -v /mnt/disk3:/data/d3 \
  -v /mnt/disk4:/data/d4 \
  mindigest/minio:RELEASE.<base>.hotfix.<sha> \
  server /data/d{1...4} --console-address ":9001"
```

- Pin the immutable tag, not `latest`.
- Pass credentials through the environment. Putting them literally on the command line leaks
  them into shell history and into `docker inspect` for anyone who can reach the daemon.
- Give each drive its own physical device. Four bind mounts on one filesystem provides no
  redundancy — a single device failure takes out every "drive" in the erasure set.

The container runs as **root** and the entrypoint's `MINIO_USERNAME`/`MINIO_GROUPNAME`
privilege-drop path is marked deprecated upstream. Constrain it from outside instead
(Kubernetes `securityContext`, `--user`, read-only root filesystem) rather than relying on
that path.

## Inspecting

```sh
docker logs -f minio
```

Confirm which build is actually running:

```sh
docker exec minio minio --version
```

Expect `RELEASE.<base>.hotfix.<sha>`. A `DEVELOPMENT.` prefix or an unexpected date means the
running image is not from this fork's build script.

Cluster health, drive status and erasure configuration:

```sh
docker exec minio mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
docker exec minio mc admin info local
```

Liveness, without credentials:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9000/minio/health/live   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9000/                    # 403 = signature check active
```

Confirm the **full** console is being served — a route that exists returns 401/403, a route
that does not returns 404:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9001/api/v1/definitely-not-a-route  # 404
for p in /admin/info /users /policies /configs /groups /kms/status /service-accounts /idp/openid; do
  printf '%-24s ' "$p"; curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:9001/api/v1$p"
done                                                                                          # 401/403
```

All 404s means a stripped object-browser build got in.

## Stopping and cleaning up

```sh
docker stop minio       # stop, keep the container
docker start minio      # start it again
docker restart minio
```

```sh
docker rm -f minio      # remove the container; data on mounted volumes is untouched
```

```sh
docker rm -f minio && rm -rf ~/minio-data   # remove the data too
```

## Upgrading

```sh
docker pull mindigest/minio:<new-tag>
docker rm -f minio
# re-run the same `docker run`, with the new tag and the same volumes
```

There is no on-disk format change between `RELEASE.2025-04-22T22-12-26Z` and
`RELEASE.2025-10-15T17-29-55Z` — `cmd/storage-datatypes*.go`, `cmd/xl-storage-format-*.go` and
the `cmd/format-erasure.go` version constants are unchanged across that range. No data
migration is needed, and rolling back is the same procedure with the older tag.

### Before upgrading from RELEASE.2025-04-22T22-12-26Z

These come from upstream, not from the fork. The full list is in
[FORK.md § Upstream behaviour changes to expect](../FORK.md#upstream-behaviour-changes-to-expect);
the two that bite first:

1. **Run your permission matrix against the new build before cutting over.** The privilege-escalation
   fix means restricted STS and service-account credentials now need explicit `Allow` on
   `admin:CreateServiceAccount`, `admin:GetUser` and `admin:ListServiceAccounts` for
   "own account" operations. This is the most likely upgrade breakage.
2. **Expect elevated background I/O for the first 24–48 hours.** Scanner-driven healing was
   disabled by a typo on every erasure deployment before `RELEASE.2025-05-24`; once it turns
   on it works through a backlog that may have been accumulating for a long time. The
   `minio_heal_*` metrics appear where there previously were none, which will flip any
   `absent()`-style alerts.
