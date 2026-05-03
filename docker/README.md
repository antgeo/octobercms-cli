# OctoberCMS Docker runtime image

The published image is a **runtime environment only**: PHP 8.3-FPM + Nginx + s6-overlay. It contains no OctoberCMS application code. You bring your own OctoberCMS project and build a derived image on top of it.

## Image tags

| Tag | Use |
|---|---|
| `ghcr.io/antgeo/octobercms:php8.3` | PHP 8.3 runtime |
| `ghcr.io/antgeo/octobercms:latest` | Latest published runtime |

Tags encode the PHP version, not the OctoberCMS version. OctoberCMS version is determined by your own `composer.json`.

---

## Building your app image

Run `octobercms init` inside your OctoberCMS project to generate all deployment files automatically, including the `Dockerfile`. The generated file:

```dockerfile
# syntax=docker/dockerfile:1.7
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN --mount=type=secret,id=OCTOBER_LICENCE_KEY \
    COMPOSER_AUTH="{\"http-basic\":{\"gateway.octobercms.com\":{\"username\":\"octobercms\",\"password\":\"$(cat /run/secrets/OCTOBER_LICENCE_KEY)\"}}}" \
    composer install --no-dev --no-scripts --prefer-dist --no-autoloader --no-interaction
COPY . .
RUN composer dump-autoload --optimize --no-dev --no-interaction

FROM ghcr.io/antgeo/octobercms:php8.3
COPY --from=vendor /app /app
RUN chown -R www-data:www-data /app
```

`OCTOBER_LICENCE_KEY` is passed by Kamal from `.kamal/secrets` via `builder.secrets` in `config/deploy.yml`. To build manually:

```sh
DOCKER_BUILDKIT=1 docker build \
  --secret id=OCTOBER_LICENCE_KEY,env=OCTOBER_LICENCE_KEY \
  -t my-org/my-site:latest .
```

The licence key is mounted only during the `composer install` step and is never written to any image layer.

---

## Running your app image

```sh
docker run -d \
  --name october \
  -p 80:80 \
  -e APP_KEY="base64:$(openssl rand -base64 32)" \
  -e APP_URL="https://example.com" \
  -e DB_CONNECTION=mysql \
  -e DB_HOST=mysql \
  -e DB_DATABASE=october \
  -e DB_USERNAME=october \
  -e DB_PASSWORD=secret \
  -v october_storage:/app/storage \
  my-org/my-site:latest
```

Run migrations once after the database is ready:

```sh
docker exec october php artisan october:migrate
```

---

## Environment variables

The entrypoint generates `/app/.env` from environment variables on container start. If `/app/.env` already exists (bind-mounted or baked into a derived image) it is left untouched.

### Required

| Variable | Example | Notes |
|---|---|---|
| `APP_KEY` | `base64:...` | Generate: `openssl rand -base64 32`, prefix with `base64:` |
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
| `STORAGE_DRIVER` | `local` | Maps to Laravel's `FILESYSTEM_DISK` |
| `CACHE_DRIVER` | `file` | |
| `SESSION_DRIVER` | `file` | |
| `QUEUE_CONNECTION` | `sync` | |
| `MAIL_MAILER` | `log` | |
| `MAIL_FROM_ADDRESS` | `hello@example.com` | |
| `MAIL_FROM_NAME` | `OctoberCMS` | |
| `LOG_CHANNEL` | `stderr` | Logs go to Docker's log driver |
| `LOG_LEVEL` | `error` | |
| `OCTOBER_LICENCE_KEY` | _(none)_ | OctoberCMS licence key. When set, `generate-env` runs `php artisan project:set` on startup to write `/app/auth.json`, enabling admin UI plugin/theme installation. Skipped if `/app/auth.json` already exists. |

---

## Volume contract

One persistent volume is required:

| Mount | Purpose |
|---|---|
| `/app/storage` | User uploads, generated thumbnails, cache, sessions, logs |

`/app/plugins` and `/app/themes` are writable by `www-data` in the base image so admin UI plugin/theme installation works in derived images. Mount them as volumes if you want those changes to persist across redeployments.

**This contract is permanent.** `/app/storage` is the writable volume for the life of the `php8.x` image series. Any change is a major version bump with a documented migration path.

---

## Process model

The container runs Nginx, PHP-FPM, and a task scheduler supervised by [s6-overlay](https://github.com/just-containers/s6-overlay) v3. Startup order:

```
generate-env (oneshot) → php-fpm (longrun) → nginx (longrun)
                       ↘ scheduler (longrun)
```

`generate-env` writes `/app/.env` from environment variables before PHP starts. Nginx waits for the PHP-FPM Unix socket before accepting connections. The scheduler runs `php artisan schedule:run` every minute via `crond`, as `www-data`.

---

## Health check

`GET /up` is routed through PHP. Your OctoberCMS application is responsible for implementing this endpoint. The `octobercms` CLI scaffolds a healthcheck plugin into new projects that returns:

- `200` — PHP-FPM responsive, database reachable, migrations table present
- `503` — one or more checks failed, JSON body identifies which

---

## Debugging

```sh
# Shell into a running container
docker exec -it <container> sh

# Run Artisan commands
docker exec <container> php artisan october:migrate
docker exec <container> php artisan cache:clear

# Tail logs
docker logs -f <container>

# Inspect the generated .env
docker exec <container> cat /app/.env
```

---

## Building the runtime image locally

```sh
git clone https://github.com/antgeo/octobercms-cli
cd octobercms-cli
docker build -f docker/Dockerfile -t octobercms:php8.3 .
```

No credentials required — the runtime image contains no OctoberCMS code.
