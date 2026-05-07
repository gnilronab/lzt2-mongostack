# lzt2-mongostack

Small Docker Compose stack for local Liztor v2 data-store experiments.

## MongoDB 8 replica set

The stack starts a single-node MongoDB 8.x replica set named `rs0` using `bitnamilegacy/mongodb:8.0`.

Note for this Omarchy host: the official MongoDB 8 images are not stable on Linux kernel 6.19 here. `mongo:8.0`/`mongo:8.3` refuse to start with MongoDB `SERVER-121912`; `mongo:8.2` starts but `mongod` exits with code 139 after ~30-60 seconds. The Debian-based Bitnami legacy MongoDB 8.0 image was verified to stay up on this host.

Apple Silicon note: `bitnamilegacy/mongodb:8.0` currently publishes a `linux/amd64` image. The compose file sets `platform: ${MONGO_PLATFORM:-linux/amd64}` for MongoDB so it can run on an M1/M2/M3 Mac through Docker Desktop's amd64 emulation while still running natively on amd64 Linux hosts like Omarchy. If you need to override it, set `MONGO_PLATFORM` before running compose.

If you previously ran this stack with the official `mongo` image, recreate the Mongo volume before switching back to Bitnami because the dbpath/layout differs:

```bash
docker compose stop mongo mongo-init
docker volume rm lzt2-mongostack_mongo-data
```

Why single-node?

- enough for local development that needs replica-set features such as transactions/change streams
- much lighter and less crash-prone on the Omarchy box than a 3-node test stack
- persistent named volumes keep the replica-set state stable across restarts
- replica-set initialization is done by a one-shot `mongo-init` service; there is intentionally no repeated MongoDB healthcheck because repeated `mongosh` checks are unnecessary for local dev and previously made debugging the official-image crash noisier

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

To start only MongoDB and initialize the replica set:

```bash
docker compose up -d mongo mongo-init
```

To start only PostgreSQL:

```bash
docker compose up -d postgres
```

## Verify Mongo

```bash
docker compose ps
docker compose exec mongo /opt/bitnami/mongodb/bin/mongosh --quiet --eval 'rs.status().ok'
docker compose exec mongo /opt/bitnami/mongodb/bin/mongosh --quiet --eval 'db.hello()'
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

## Connect from a Java/Spring container on the same machine

If the Spring Boot app runs as another container in this same compose project, use the compose service names as hostnames:

```yaml
services:
  app:
    image: your-spring-app:latest
    depends_on:
      mongo-init:
        condition: service_completed_successfully
      postgres:
        condition: service_healthy
    environment:
      SPRING_DATA_MONGODB_URI: mongodb://mongo:27017/lzt2?replicaSet=rs0
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/lzt2
      SPRING_DATASOURCE_USERNAME: lzt2
      SPRING_DATASOURCE_PASSWORD: lzt2-dev-password
```

Equivalent `application.yaml` values:

```yaml
spring:
  data:
    mongodb:
      uri: mongodb://mongo:27017/lzt2?replicaSet=rs0
  datasource:
    url: jdbc:postgresql://postgres:5432/lzt2
    username: lzt2
    password: lzt2-dev-password
```

If the Spring Boot app runs in a separate compose project or as a plain `docker run` container, attach it to this stack's Docker network:

```bash
# check network name
docker network ls | grep lzt2-mongostack

# example: run app on the same network
docker run --rm --network lzt2-mongostack_default \
  -e SPRING_DATA_MONGODB_URI='mongodb://mongo:27017/lzt2?replicaSet=rs0' \
  -e SPRING_DATASOURCE_URL='jdbc:postgresql://postgres:5432/lzt2' \
  -e SPRING_DATASOURCE_USERNAME='lzt2' \
  -e SPRING_DATASOURCE_PASSWORD='lzt2-dev-password' \
  your-spring-app:latest
```

From a container, do not use `localhost` for Mongo/Postgres unless the database is inside that same container. Use `mongo` and `postgres` on the compose network.

## Stop

```bash
docker compose down
```

To delete all database data as well:

```bash
docker compose down -v
```
