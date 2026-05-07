# lzt2-mongostack

Small Docker Compose stack for local Liztor v2 data-store experiments.

## MongoDB 8 replica set

The stack starts a single-node MongoDB 8.x replica set named `rs0` using `mongo:8.2`.

Note for this Omarchy host: `mongo:8.0` currently fails immediately on Linux kernel 6.19 with MongoDB `SERVER-121912` (`MongoDB cannot start: Linux kernel versions 6.19 and newer has a known incompatibility with this version of MongoDB`). `mongo:8.2` was verified to start cleanly here.

Why single-node?

- enough for local development that needs replica-set features such as transactions/change streams
- much lighter and less crash-prone on the Omarchy box than a 3-node test stack
- persistent named volumes keep the replica-set state stable across restarts

## PostgreSQL 18

The same compose project also starts a completely separate PostgreSQL 18 service. It does not depend on, connect to, or share volumes with MongoDB.

Note: PostgreSQL 18 Docker images expect the persistent volume at `/var/lib/postgresql` rather than the old `/var/lib/postgresql/data` mount style.

Host connection:

```text
postgresql://lzt2:lzt2-dev-password@localhost:5432/lzt2
```

Connection from another service in this compose project:

```text
postgresql://lzt2:lzt2-dev-password@postgres:5432/lzt2
```

## Start

```bash
docker compose up -d
```

To start only MongoDB:

```bash
docker compose up -d mongo
```

To start only PostgreSQL:

```bash
docker compose up -d postgres
```

## Verify Mongo

```bash
docker compose ps
docker compose exec mongo mongosh --quiet --eval 'rs.status().ok'
docker compose exec mongo mongosh --quiet --eval 'db.hello()'
```

## Verify PostgreSQL

```bash
docker compose exec postgres psql -U lzt2 -d lzt2 -c 'select version();'
```

Connection URI from the host:

```text
mongodb://localhost:27017/?replicaSet=rs0
```

Connection URI from another service in this compose project:

```text
mongodb://mongo:27017/?replicaSet=rs0
```

## Stop

```bash
docker compose down
```

To delete all database data as well:

```bash
docker compose down -v
```
