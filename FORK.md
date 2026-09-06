# mindigest/minio

A fork of [minio/minio](https://github.com/minio/minio) that keeps the **full web console**
on a **current release**.

## The one change

`main` is upstream `RELEASE.2025-10-15T17-29-55Z` (commit `9e49d5e7a`) plus commits that touch
only `go.mod` / `go.sum`, the `Dockerfile`, the build script, and this documentation. The
functional delta is a single line:

```
-	github.com/minio/console v1.7.7-0.20250905210349-2017f33b26e1
+	github.com/minio/console v1.7.6
```

**No MinIO server code is patched.** Verify at any time:

```sh
git diff --stat RELEASE.2025-10-15T17-29-55Z..main -- cmd/ internal/   # must be empty
go list -m github.com/minio/console                                    # must be v1.7.6
```

## Why

Upstream walked the console away from the full admin UI:

| Upstream release | `github.com/minio/console` |
| --- | --- |
| `RELEASE.2025-04-22T22-12-26Z` | **v1.7.6** — last tagged release with the full console |
| `RELEASE.2025-05-24T17-08-30Z` | v1.7.7-0.20250516212319 |
| `RELEASE.2025-07-18T21-56-31Z` | v1.7.7-0.20250623221437 |
| `RELEASE.2025-09-06T17-38-46Z` and later | v1.7.7-0.20250905210349 — upstream renamed to **object-browser v2.x** |

Staying on `RELEASE.2025-04-22T22-12-26Z` to keep the console means running without two P0
fixes that landed later:

- **`63e102c04`** (in `RELEASE.2025-05-24`) — a one-character typo in `cmd/data-scanner.go`
  (`if globalIsErasure ||` instead of `if !globalIsErasure ||`) disabled scanner-driven
  healing on **every** erasure deployment. Objects that lost shards were never repaired in
  the background; parity eroded silently.
- **`c1a49490c`** (in `RELEASE.2025-10-15`) — `sessionPolicyArgs.DenyOnly` caused inline
  session policies on service-account and STS credentials to be skipped on "own account"
  admin operations. A restricted credential could create a new service account for itself
  with no session policy, inheriting the parent's full permissions.

This combination is safe because the console integration surface did not change between
those releases: the same four import paths, and a byte-identical `initConsoleServer()` call
sequence in `cmd/common-main.go`. `madmin-go/v3` is `v3.0.109` at both ends, so
`console v1.7.6 + madmin-go v3.0.109` is the exact combination `RELEASE.2025-04-22T22-12-26Z`
already shipped.

## Building

```sh
buildscripts/build-fork.sh
```

That is the only supported path. It cross-compiles the Linux binary with correct version
stamping and builds the container image.

```sh
PLATFORM=linux/arm64 buildscripts/build-fork.sh    # different target
BINARY_ONLY=1 buildscripts/build-fork.sh           # skip the image
REPO=myorg/minio buildscripts/build-fork.sh        # different image repo
```

### Do not use the upstream build paths

| Path | What actually happens |
| --- | --- |
| `go install github.com/minio/minio@latest` | Builds **upstream**, not this fork — you get the stripped console. |
| `make build` | Stamps the version from HEAD's *commit date*, so the binary claims today's date instead of the upstream release it is based on. |
| `make hotfix` | Uses `sed 's#...\+...#'`, a GNU-only extension. On BSD/macOS sed the substitution silently no-ops, `gen-ldflags.go` panics, `$(shell ...)` swallows the panic, `LDFLAGS` ends up **empty** — and `go build` still exits 0 with an unstamped, unstripped binary. |
| `make docker` | Tags into `quay.io/minio` (upstream's namespace) and builds a host-native binary, i.e. a macOS binary inside a Linux image. |

### Guards in the build script

The script refuses to produce an artifact rather than produce a wrong one:

- `github.com/minio/console` is not the pinned version → **fail** (this is the fork's reason to exist)
- `gen-ldflags.go` produced empty or unexpected `LDFLAGS` → **fail**
- the working tree is dirty (`vcs.modified=true` in the binary) → **fail**
- the Go toolchain is pinned to the `toolchain` directive in `go.mod`, not whatever is installed

## Releasing

```sh
buildscripts/build-fork.sh
docker push mindigest/minio:RELEASE.<base>.hotfix.<sha>
docker push mindigest/minio:RELEASE.<base>-console1.7.6
docker push mindigest/minio:latest
git tag -a RELEASE.<base>.hotfix.<sha> -m "..." <sha> && git push origin RELEASE.<base>.hotfix.<sha>
```

Tags:

- **`RELEASE.<base>.hotfix.<sha>`** — immutable, and byte-identical to what `minio --version`
  reports, so a running container always names an image tag that still exists.
- **`RELEASE.<base>-console1.7.6`** and **`latest`** — moving, repointed every build.

## Rebasing onto a newer upstream release

Upstream declared the repository unmaintained (2026-02) and published no community image
after `RELEASE.2025-09-07T16-13-09Z`, so this may never be needed. If a new upstream release
does appear:

```sh
git fetch upstream --tags
git rebase --onto <NEW_TAG> RELEASE.2025-10-15T17-29-55Z main
```

**The rebase will conflict on the `go.mod` console line. Keep `v1.7.6` — never take
upstream's.** Taking theirs is the natural instinct on a dependency bump and it silently
restores the stripped object-browser, which is the one thing this fork exists to prevent.
`buildscripts/build-fork.sh` will refuse to build if this happens, but only if someone runs it.

Then:

```sh
go mod tidy
go list -m github.com/minio/console          # must still be v1.7.6
git diff --stat <NEW_TAG>..main -- cmd/ internal/   # must be empty
buildscripts/build-fork.sh
```

Re-run the verification below before shipping. If console v1.7.6 no longer compiles or the
admin API has drifted, that is the signal that this fork has reached its end and the choice
between "current server" and "full console" is real again.

Also update, in the same commit: the base tag named in the `README.md` banner, the
`description` label in `Dockerfile`, and the rebase base tag in this file.

## Verifying a build

`minio --version` proves the server version. It does **not** prove which console is embedded.
For that, start the server and probe the console API — a route that exists returns 401/403,
a route that does not exist returns 404:

```sh
docker run -d --name mv -p 9001:9001 mindigest/minio:<tag> server /data --console-address ":9001"

curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9001/api/v1/definitely-not-a-route   # expect 404
for p in /admin/info /users /policies /configs /groups /kms/status /service-accounts /idp/openid; do
  printf '%-24s ' "$p"; curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:9001/api/v1$p"
done                                                                                            # expect 401/403

docker rm -f mv
```

All 404s means the stripped object-browser got in. Console v1.7.6 serves 88 routes under
`/api/v1`; the module source is in `$(go env GOMODCACHE)/github.com/minio/console@v1.7.6/api/`.

## Deliberate omissions

- **CI/CD is removed.** All 17 upstream workflows were gated on a `master` branch that does
  not exist here, except `lock.yml` (schedule) and `vulncheck.yml` (push), which fired anyway
  and failed, and `issues.yaml`, which posted into MinIO's own org project board. GitHub
  Actions is also disabled at the repository level.
- **Single platform.** Images are `linux/amd64` only. Upstream ships a three-architecture
  manifest list; an `arm64` node pulling this image gets emulation. Build with
  `PLATFORM=linux/arm64` if you need it.
- **The base image is ~12 months old.** `Dockerfile` is pinned to
  `minio/minio:RELEASE.2025-09-07T16-13-09Z`, the newest community image upstream ever
  published. Its userland (bash, coreutils) is correspondingly dated. Rebasing onto a
  different, actively maintained base is the only fix, and it means re-deriving the runtime
  contract (entrypoint, `mc`, CA bundle) rather than inheriting it.

## Upstream behaviour changes to expect

Migrating from `RELEASE.2025-04-22T22-12-26Z`, these come from upstream, not from this fork:

1. **IAM tightening** — the other side of `c1a49490c`. Restricted STS / service-account
   credentials now need explicit `Allow` on `admin:CreateServiceAccount`, `admin:GetUser` and
   `admin:ListServiceAccounts` for "own account" operations. **Test your permission matrix
   before deploying** — this is the most likely upgrade breakage.
2. **`If-Match` no longer acts as an unconditional create** — clients using it as an
   idempotent upsert start getting 404s.
3. **CopyObject rewrites object data** — an automatic CRC64NVME checksum sets
   `metadataOnly=false`, so in-place copies of large objects get materially slower.
4. **Background healing turns on** — expect elevated heal I/O for the first 24–48 hours while
   it works through the backlog, and `minio_heal_*` metrics appearing where there were none.
5. **v3 replication metrics gain a `targetArn` label** — 17–18 series change identity.
6. **`MINIO_COMPRESS*` starts taking effect** if it was set and silently inert before.
7. **FIPS 140-2 / boringcrypto support is gone** — the `fips` build tag is a no-op.
8. **Helm**: `global.imagePullSecrets` changed from a list of strings to a list of objects;
   buckets without an explicit `versioning` value are no longer force-suspended.

## Licence

Unchanged: GNU AGPLv3, identical to upstream. Publishing modified builds carries the AGPLv3
source-availability obligation; this repository is that source.
