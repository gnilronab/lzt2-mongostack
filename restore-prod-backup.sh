#!/usr/bin/env bash
# Restore an Atlas dbPath snapshot into the local lzt2-mongostack mongo volume.
#
# Usage:
#   ./restore-prod-backup.sh [path]
#
# `path` may be:
#   - a .tar.gz produced by Atlas "Download Snapshot"
#   - a directory containing one (or the extracted restore-<id>/ tree)
#   - omitted, in which case mongoprodbackup/ is searched
#
# What it does:
#   1. Stops the compose stack.
#   2. Wipes the mongo-data volume and copies the snapshot's WiredTiger files
#      into /bitnami/mongodb/data/db with bitnami ownership (1001:1001).
#   3. Boots mongod standalone (no --replSet) and drops the `local` database
#      so Atlas's replset config doesn't poison rs.initiate().
#   4. Brings the compose stack back up; mongo-init runs rs.initiate() as usual.

set -euo pipefail

PROJECT="lzt2-mongostack"
VOLUME="${PROJECT}_mongo-data"
MONGO_IMAGE="bitnamilegacy/mongodb:8.0"
PLATFORM="${MONGO_PLATFORM:-linux/amd64}"
TMP_CONTAINER="lzt2-mongo-restore"

SRC="${1:-mongoprodbackup}"

if [[ ! -e "$SRC" ]]; then
  echo "error: $SRC does not exist" >&2
  exit 1
fi

# Resolve $SRC to either an extracted restore-* directory we can bind-mount,
# or a tarball path we'll extract inside the helper container.
HOST_BACKUP_DIR=""
HOST_TARBALL=""

if [[ -f "$SRC" && "$SRC" == *.tar.gz ]]; then
  HOST_TARBALL="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
elif [[ -d "$SRC" ]]; then
  # Look for a restore-* dir, or a single tarball, inside $SRC.
  RESTORE_DIR="$(find "$SRC" -maxdepth 2 -type d -name 'restore-*' | head -1 || true)"
  if [[ -n "$RESTORE_DIR" ]]; then
    HOST_BACKUP_DIR="$(cd "$RESTORE_DIR" && pwd)"
  else
    TARBALL="$(find "$SRC" -maxdepth 1 -type f -name '*.tar.gz' | head -1 || true)"
    if [[ -n "$TARBALL" ]]; then
      HOST_TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"
    else
      echo "error: no restore-*/ dir or *.tar.gz found in $SRC" >&2
      exit 1
    fi
  fi
else
  echo "error: $SRC is neither a .tar.gz nor a directory" >&2
  exit 1
fi

echo
echo "About to:"
echo "  - stop the $PROJECT compose stack"
echo "  - wipe Docker volume $VOLUME"
if [[ -n "$HOST_BACKUP_DIR" ]]; then
  echo "  - load snapshot from $HOST_BACKUP_DIR"
else
  echo "  - extract snapshot from $HOST_TARBALL"
fi
echo "  - drop the 'local' DB and reinitiate replica set rs0"
echo
read -rp "Continue? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }

echo "==> docker compose down"
docker compose down >/dev/null

# Make sure no stale helper container is left over from a previous run.
docker rm -f "$TMP_CONTAINER" >/dev/null 2>&1 || true

echo "==> wiping volume and loading snapshot"
if [[ -n "$HOST_BACKUP_DIR" ]]; then
  docker run --rm --platform "$PLATFORM" --user 0:0 \
    -v "$VOLUME":/bitnami/mongodb \
    -v "$HOST_BACKUP_DIR":/snapshot:ro \
    --entrypoint bash \
    "$MONGO_IMAGE" -lc '
      set -euo pipefail
      rm -rf /bitnami/mongodb/data
      mkdir -p /bitnami/mongodb/data/db
      cp -a /snapshot/. /bitnami/mongodb/data/db/
      chown -R 1001:1001 /bitnami/mongodb
    '
else
  docker run --rm --platform "$PLATFORM" --user 0:0 \
    -v "$VOLUME":/bitnami/mongodb \
    -v "$HOST_TARBALL":/snapshot.tar.gz:ro \
    --entrypoint bash \
    "$MONGO_IMAGE" -lc '
      set -euo pipefail
      rm -rf /bitnami/mongodb/data
      mkdir -p /tmp/extract /bitnami/mongodb/data/db
      tar -xzf /snapshot.tar.gz -C /tmp/extract
      src=$(find /tmp/extract -maxdepth 2 -type d -name "restore-*" | head -1)
      if [ -z "$src" ]; then
        echo "no restore-* dir inside tarball" >&2
        exit 1
      fi
      cp -a "$src"/. /bitnami/mongodb/data/db/
      chown -R 1001:1001 /bitnami/mongodb
    '
fi

echo "==> booting mongod standalone to clean up Atlas replset metadata"
docker run -d --name "$TMP_CONTAINER" --platform "$PLATFORM" \
  -v "$VOLUME":/bitnami/mongodb \
  --entrypoint bash \
  "$MONGO_IMAGE" -lc '
    exec /opt/bitnami/mongodb/bin/mongod \
      --bind_ip_all --port 27017 \
      --dbpath /bitnami/mongodb/data/db
  ' >/dev/null

echo -n "    waiting for mongod"
for i in {1..60}; do
  if docker exec "$TMP_CONTAINER" /opt/bitnami/mongodb/bin/mongosh --quiet \
      --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -q 1; then
    echo " ready"
    break
  fi
  echo -n "."
  sleep 1
done

echo "==> dropping 'local' database (clears Atlas replset config)"
docker exec "$TMP_CONTAINER" /opt/bitnami/mongodb/bin/mongosh --quiet --eval '
  db.getSiblingDB("local").dropDatabase()
'

echo "==> stopping standalone mongod"
docker stop "$TMP_CONTAINER" >/dev/null
docker rm "$TMP_CONTAINER" >/dev/null

echo "==> docker compose up -d"
docker compose up -d

echo
echo "Done. Tail logs with:  docker logs -f lzt2-mongo-init"
echo "Verify replset with:   docker exec lzt2-mongo /opt/bitnami/mongodb/bin/mongosh --quiet --eval 'rs.status().ok'"
