# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

**M1 (Docker runtime image) is complete. M2 (licence key management) is complete.** M3 (gem skeleton + `init` command) is next.

## What this project is

**Third-party project — not affiliated with or endorsed by the OctoberCMS team.**

A Ruby gem (`octobercms`) and Docker image that make deploying OctoberCMS a single-command operation. The gem wraps **Kamal** as the deployment engine and adds OctoberCMS-aware scaffolding, lifecycle commands, and account API integration.

Three artifacts together form the product:
1. **`ghcr.io/antgeo/octobercms` Docker image** — runtime environment only: PHP-FPM + Nginx + s6-overlay. No OctoberCMS code is baked in. Users bring their own OctoberCMS project and build a derived image.
2. **`octobercms` Ruby gem** — Thor-based CLI, TTY toolkit for UX, shells out to Kamal via `tty-command`
3. **Deploy template** — what `octobercms init` generates into the customer's project directory (ERB templates rendered at init time)

## The Docker image (M1 — complete)

The image is a **runtime environment only**. It contains no OctoberCMS application code. Users build a derived image:

```dockerfile
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN --mount=type=secret,id=composer_auth,target=/app/auth.json,required=true \
    composer install --no-dev --no-scripts --prefer-dist --no-autoloader --no-interaction
COPY . .
RUN composer dump-autoload --optimize --no-dev --no-interaction

FROM ghcr.io/antgeo/octobercms:php8.3
COPY --from=vendor /app /app
RUN chown -R www-data:www-data /app
```

Image tags encode the PHP version, not the OctoberCMS version:
- `ghcr.io/antgeo/octobercms:php8.3`
- `ghcr.io/antgeo/octobercms:latest`

### Docker image contract (public API — no changes without major version bump)

- `/app/storage` — the only required persistent volume (uploads, cache, sessions, logs)
- `/app/plugins` and `/app/themes` — writable by `www-data` for admin UI plugin/theme installation; mount as volumes to persist across redeployments
- Runtime config via environment variables; `generate-env` oneshot writes `/app/.env` before PHP starts
- Health check: `GET /up` — the OctoberCMS application is responsible for implementing this endpoint
- Image size target: <300 MB compressed (CI enforces this)

### Building and testing the runtime image

```sh
# Build locally
docker build -f docker/Dockerfile -t octobercms:base .

# Run all tests (unit + integration)
bundle exec rspec

# Run integration tests only (requires image built as octobercms:base)
OCTOBERCMS_INFRA_IMAGE=octobercms:base bundle exec rspec --tag integration

# Run a single spec file
bundle exec rspec spec/unit/generate_env_spec.rb

# Run without slow integration tags
bundle exec rspec --tag '~integration'
```

Ruby requirement: **3.2+**.

## Process model (inside the container)

```
generate-env (oneshot) → php-fpm (longrun) → nginx (longrun)
```

s6-overlay v3 supervises PHP-FPM and Nginx. `generate-env` writes `/app/.env` from environment variables before PHP starts. If `/app/.env` already exists (bind-mounted or baked in), it is left untouched. Nginx waits for the PHP-FPM Unix socket (`/run/php-fpm.sock`) before accepting connections.

## Gem structure (M2 — implemented)

```
bin/octobercms               # CLI entrypoint
lib/octobercms/
  cli.rb                     # Thor command tree root
  version.rb
  commands/
    auth.rb                  # auth setup / status / remove
  services/
    auth_store.rb            # credential resolution + storage
spec/
  unit/
    auth_commands_spec.rb    # 38 tests for auth commands
    auth_store_spec.rb       # 16 tests for AuthStore
```

### auth_store.rb — credential resolution order

1. `OCTOBER_LICENCE_KEY` environment variable (highest priority, CI/operator)
2. `OCTOBER_LICENCE_KEY` in `.kamal/secrets` (per-project key)
3. `~/.config/octobercms/auth.yml` (global default, `licence_key:` key)

`AuthStore.resolve(project_dir:)` returns `{key: String, source: :env | :project | :global}` or `nil`.

File writes are atomic: write to `.tmp` → `chmod 0600` → rename. Keys in `.kamal/secrets` are stored quoted: `OCTOBER_LICENCE_KEY="value"`. Reader strips surrounding quotes for backward compatibility.

### validate_key — how it works

`auth setup` and `auth status --validate` hit `https://gateway.octobercms.com/packages.json` with HTTP Basic auth (username: `octobercms`, password: licence key). `200` → valid, `401` → rejected, other → unexpected. The licence key is redacted from all output.

### Key gem dependencies

- **Thor** (`~> 1.3`) — command tree; `raise Thor::Error` for user-facing errors
- **tty-prompt** (`~> 0.23`) — masked key input, yes/no confirms, select menus
- **tty-command, tty-logger** (`~> 0.10`, `~> 0.6`) — reserved for M4 deploy pipeline
- **Net::HTTP** (stdlib) — gateway validation; no extra HTTP gem dependency in M2

### Running gem tests

```sh
bundle exec rspec spec/unit/auth_store_spec.rb
bundle exec rspec spec/unit/auth_commands_spec.rb
bundle exec rspec --tag '~integration'  # all unit tests
```

## Planned gem additions (M3+)

```
lib/octobercms/commands/
  init.rb / deploy.rb / plugin.rb / backup.rb / doctor.rb
lib/octobercms/generators/   # ERB template renderers
lib/octobercms/services/
  kamal.rb / composer.rb / docker.rb / api_client.rb
lib/octobercms/templates/    # Dockerfile, deploy.yml, etc.
```

Commands are thin (parsing, prompting, dispatching). Logic lives in services and generators.

## Architecture: how deploy works

`octobercms deploy` pipeline (run inside the user's OctoberCMS project repo):

1. **Pre-flight** — auth state, licence health, composer.lock validity
2. **Build** — fetches licence key from OctoberCMS API → writes temp `auth.json` → `docker build DOCKER_BUILDKIT=1 --secret id=composer_auth,src=<temp>` against the user's `Dockerfile` (which derives FROM the runtime image) → deletes temp file in `begin/ensure`
3. **Push** — `kamal registry login && docker push`
4. **Migrate** — one-shot container runs `php artisan october:migrate` **before** rolling deploy
5. **Deploy** — `kamal deploy` (rolling restart via `/up` health check)
6. **Post-deploy** — cache clear, optional route warming

Each step is also its own subcommand (`octobercms build`, `octobercms migrate`, etc.) for debugging.

## Architecture: authentication and secrets

**Account auth (OAuth browser flow):**
- `octobercms auth login` opens browser to `https://octobercms.com/cli/authorize?code=<random>`, local HTTP listener captures callback token
- Token stored at `~/.config/octobercms/auth.yml` (mode `0600`)
- CI uses `OCTOBER_API_TOKEN` env var instead
- Token grants read access to Project Licences only; never logged or displayed

**Licence credential flow:**
- `init` stores only the Project ID in `.kamal/project` (committable, not secret)
- At build time, licence key is fetched from API per-build, injected via BuildKit secret mount, **never persisted** in the project directory or image layers
- Runtime container has no licence credentials

**Never log or display the licence key or account token under any circumstance, including `--verbose` mode.** Redact any matching pattern from all output.

## Engineering principles

- **Wrap Kamal, don't fork it.** Shell out via `tty-command`. The user sees `octobercms deploy`, not `kamal deploy`.
- **Generated config is hand-editable.** Generators detect existing files and prompt or merge rather than clobber.
- **Doctor catches support tickets.** Every environmental issue that turns into a support ticket becomes a new `doctor` check. Doctor is the support team's first line of defence.
- **The volume contract is sacred.** `/app/storage` is the writable volume forever.
- **Secrets never enter image layers.** BuildKit secret mounts only. CI verifies via `docker history` inspection.
- **Migrations run before rolling deploy**, not during it, to avoid race conditions.
- **The runtime image is just a runtime.** OctoberCMS code lives in the user's project, not in this repo.

## Plugin management

The `octobercms` CLI (future milestone) scaffolds a derived `Dockerfile` into the user's project. Plugin install paths:
- **Build-time (primary):** Composer in the derived image's vendor stage
- **Admin UI (runtime):** `/app/plugins` and `/app/themes` are writable; mount as volumes if persistence across redeployments is needed
- **Local-path plugins:** a `plugins/` directory in the user's project is COPYed into their derived image at build
- Plugin index YAML ships with the gem: maps friendly names (`rainlab.user`) to Packagist packages (`rainlab/user`)
