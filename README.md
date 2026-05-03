# OctoberCMS CLI

> **This is an independent, third-party project.** It is not affiliated with, endorsed by, or maintained by the OctoberCMS team. OctoberCMS is a trademark of its respective owners.

A Ruby gem and Docker image that make deploying OctoberCMS a single-command operation against any Linux server. Built on [Kamal](https://kamal-deploy.org) as the deployment engine.

> **Status:** M1 (Docker image) — the gem is in development.

---

## Docker image

### Quick start

```sh
docker run -d \
  --name october \
  -p 80:80 \
  -e APP_KEY="base64:$(openssl rand -base64 32)" \
  -e APP_URL="http://localhost" \
  -e DB_CONNECTION=mysql \
  -e DB_HOST=mysql \
  -e DB_DATABASE=october \
  -e DB_USERNAME=october \
  -e DB_PASSWORD=secret \
  -v october_storage:/app/storage \
  ghcr.io/octobercms/octobercms:latest
```

Run migrations once after the database is ready:

```sh
docker exec october php artisan october:migrate
```

The site is available at `http://localhost`. The `/up` health check endpoint confirms the stack is fully operational:

```sh
curl http://localhost/up
# {"status":"ok","checks":{"php_fpm":"ok","database":"ok","migrations_table":"ok"}}
```

### Image tags

| Tag | PHP version | Use |
|---|---|---|
| `octobercms:latest` | 8.3 | Latest stable |
| `octobercms:4.2` | 8.3 | OctoberCMS 4.2, default PHP |
| `octobercms:4.2-php8.3` | 8.3 | OctoberCMS 4.2, PHP 8.3 (specific) |

Tags are immutable. `latest` always points to the most recently published stable minor.

---

## Environment variables

All runtime configuration is passed via environment variables. An entrypoint script generates `/app/.env` from these on container start.

### Required

| Variable | Example | Notes |
|---|---|---|
| `APP_KEY` | `base64:...` | Generate with `openssl rand -base64 32`, prefix with `base64:` |
| `APP_URL` | `https://example.com` | Full URL including scheme |
| `DB_CONNECTION` | `mysql` | |
| `DB_HOST` | `mysql` | |
| `DB_DATABASE` | `october` | |
| `DB_USERNAME` | `october` | |
| `DB_PASSWORD` | `secret` | |

### Optional

| Variable | Default | Notes |
|---|---|---|
| `APP_NAME` | `OctoberCMS` | |
| `APP_ENV` | `production` | |
| `APP_DEBUG` | `false` | |
| `APP_LOCALE` | `en` | |
| `DB_PORT` | `3306` | |
| `STORAGE_DRIVER` | `local` | `local` only in v1; `s3` and `r2` in v2 |
| `CACHE_DRIVER` | `file` | |
| `SESSION_DRIVER` | `file` | |
| `QUEUE_CONNECTION` | `sync` | |
| `MAIL_MAILER` | `log` | |
| `MAIL_FROM_ADDRESS` | `hello@example.com` | |
| `MAIL_FROM_NAME` | `OctoberCMS` | |
| `LOG_CHANNEL` | `stderr` | Logs go to Docker's log driver by default |
| `LOG_LEVEL` | `error` | |

If `/app/.env` already exists in the container (bind-mounted or baked into a derived image), the entrypoint skips generation entirely.

---

## Volume contract

Three persistent volumes are required:

| Mount | Purpose |
|---|---|
| `/app/storage` | User uploads, generated thumbnails, cache, sessions, logs |
| `/app/plugins` | Plugins — seeded from image defaults on first run, then managed via admin UI or Composer |
| `/app/themes` | Themes — seeded from image defaults on first run, then managed via admin UI |

On first run with a fresh volume, `/app/plugins` and `/app/themes` are automatically populated from the image's built-in defaults. Subsequent container restarts leave the volume contents untouched, so anything installed via the admin UI persists across deployments.

> **Note:** Plugins that require additional Composer packages (i.e. have their own `composer.json` dependencies beyond OctoberCMS core) cannot be installed via the admin UI. Manage those in a derived `Dockerfile` using Composer.

**This contract is permanent.** Once published, these three volume mounts are the writable surface for the life of the `4.x` image series. Any change is a major version bump with a documented migration path.

---

## Building a custom image

Create a `Dockerfile` in your project that derives from this image and installs your plugins via Composer:

```dockerfile
# syntax=docker/dockerfile:1.7
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN --mount=type=secret,id=composer_auth,target=/app/auth.json,required=true \
    composer install --no-dev --no-scripts --prefer-dist --no-autoloader --no-interaction
COPY . .
RUN composer dump-autoload --optimize --no-dev --no-interaction

FROM ghcr.io/octobercms/octobercms:4.2
COPY --from=vendor /app/vendor /app/vendor
COPY plugins/ /app/plugins/
```

The `composer_auth` secret mount injects your OctoberCMS gateway credential (`auth.json`) only for the duration of `composer install`. It is never written to any image layer.

Build with:

```sh
DOCKER_BUILDKIT=1 docker build \
  --secret id=composer_auth,src=$HOME/.composer/auth.json \
  -t my-org/my-site:latest .
```

---

## Process model

The container runs Nginx and PHP-FPM in a single process, supervised by [s6-overlay](https://github.com/just-containers/s6-overlay) v3. Service startup order:

```
generate-env (oneshot) → php-fpm (longrun) → nginx (longrun)
```

`generate-env` writes `/app/.env` from environment variables before PHP starts. Nginx waits for the PHP-FPM Unix socket before accepting connections.

---

## Health check

`GET /up` returns `200` when:
- PHP-FPM is responsive (implicit — the request reached application code)
- The database is reachable
- The `migrations` table exists (confirming `october:migrate` has run)

Returns `503` with a JSON body identifying which check failed:

```json
{
  "status": "error",
  "checks": {
    "php_fpm": "ok",
    "database": "ok",
    "migrations_table": "missing"
  }
}
```

---

## Debugging

**Shell into a running container:**

```sh
docker exec -it <container> sh
```

**Run a one-off Artisan command:**

```sh
docker exec <container> php artisan october:migrate
docker exec <container> php artisan cache:clear
docker exec <container> php artisan october:version
```

**Tail application logs:**

```sh
docker logs -f <container>
```

PHP-FPM and Nginx both write to stderr, captured by Docker's log driver.

**Inspect the generated `.env`:**

```sh
docker exec <container> cat /app/.env
```

---

## Building the base image locally

```sh
# Clone the repo
git clone https://github.com/octobercms/octobercms-cli
cd octobercms-cli

# Build (no credentials needed for a dev build)
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile -t octobercms:dev .

# Run against a local MySQL
docker run -p 80:80 \
  -e APP_KEY="base64:$(openssl rand -base64 32)" \
  -e APP_URL=http://localhost \
  -e DB_CONNECTION=mysql \
  -e DB_HOST=host.docker.internal \
  -e DB_DATABASE=october \
  -e DB_USERNAME=october \
  -e DB_PASSWORD=secret \
  -v october_storage:/app/storage \
  octobercms:dev
```

### Bootstrapping `composer.lock`

`composer.lock` must be committed for reproducible builds but requires an OctoberCMS gateway credential to generate. One-time setup on a machine with a valid `auth.json`:

```sh
DOCKER_BUILDKIT=1 docker build \
  --secret id=composer_auth,src=$HOME/.composer/auth.json \
  --target vendor \
  --output type=local,dest=./vendor-out \
  -f docker/Dockerfile .

cp vendor-out/app/composer.lock ./composer.lock
rm -rf vendor-out
git add composer.lock && git commit -m "Add initial composer.lock"
```

After this, all CI and local builds use the committed lock file and no longer need gateway credentials to resolve package versions.
