# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

**M1 (Docker runtime image), M2 (licence key management), M3 (`init` command + file generators), and M4 (deploy command pipeline) are complete.** M5 (plugin management) is next.

## What this project is

**Third-party project — not affiliated with or endorsed by the OctoberCMS team.**

A Ruby gem (`octobercms`) and Docker image that make deploying OctoberCMS a single-command operation. The gem wraps **Kamal** as the deployment engine and adds OctoberCMS-aware scaffolding, lifecycle commands, and account API integration.

Three artifacts together form the product:
1. **`ghcr.io/antgeo/octobercms` Docker image** — runtime environment only: PHP-FPM + Nginx + s6-overlay. No OctoberCMS code is baked in. Users bring their own OctoberCMS project and build a derived image.
2. **`octobercms` Ruby gem** — Thor-based CLI, TTY toolkit for UX, shells out to Kamal via `tty-command`
3. **Deploy template** — what `octobercms init` generates into the customer's project directory (ERB templates rendered at init time)

## The Docker image (M1 — complete)

The image is a **runtime environment only**. It contains no OctoberCMS application code. `octobercms init` generates a `Dockerfile` into the user's project:

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

`OCTOBER_LICENCE_KEY` is passed from `.kamal/secrets` by Kamal as a BuildKit secret via `builder.secrets` in `config/deploy.yml`. `COMPOSER_AUTH` injects it into Composer only during the install step — it never enters image layers.

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

## Gem structure (M4 — current)

```
bin/octobercms               # CLI entrypoint
lib/octobercms/
  cli.rb                     # Thor command tree root — all commands registered here
  version.rb                 # 0.1.0
  commands/
    auth.rb                  # auth setup / status / remove (Thor subclass)
    init.rb                  # octobercms init (plain Ruby class, call via CLI)
    deploy.rb                # octobercms deploy / build / migrate / console / logs
    doctor.rb                # octobercms doctor — 8-check pre-deploy checklist
  generators/
    base.rb                  # render_template (ERB) + atomic write_file helpers
    dockerfile.rb            # renders Dockerfile.erb
    deploy_yml.rb            # renders deploy.yml.erb → config/deploy.yml
    secrets.rb               # renders secrets.erb → .kamal/secrets (mode 0600)
    env_example.rb           # renders env.example.erb → .env.example
    gitignore.rb             # append-only: auth.json, .env, .kamal/secrets
    dockerignore.rb          # append-only: .git, .gitignore, .env, auth.json, .kamal/secrets, vendor
  services/
    auth_store.rb            # credential resolution + storage
    kamal.rb                 # tty-command wrapper; licence key redaction; run / run!
  templates/
    Dockerfile.erb
    deploy.yml.erb
    secrets.erb
    env.example.erb
spec/
  unit/
    auth_commands_spec.rb    # 38 tests for auth commands
    auth_store_spec.rb       # 16 tests for AuthStore
    init_command_spec.rb     # 17 tests for Init
    deploy_command_spec.rb   # 26 tests for Deploy
    doctor_command_spec.rb   # 34 tests for Doctor
    generators/
      dockerfile_spec.rb
      deploy_yml_spec.rb
      secrets_spec.rb
      env_example_spec.rb
      gitignore_spec.rb
      dockerignore_spec.rb
    services/
      kamal_spec.rb          # 9 tests for Services::Kamal
```

### Commands::Deploy — deploy lifecycle

`deploy.rb` is a plain Ruby class registered as methods on `CLI < Thor`. Key methods:

- `call` — full pipeline (pre-flight → build push → migrate → deploy)
- `build_only` — `kamal build push` only
- `migrate_only` — `kamal app exec --reuse 'php artisan october:migrate'` only
- `console` — calls `Kernel#exec("kamal", "app", "exec", "--interactive", "bash", ...)` to replace the process and give Kamal the real TTY
- `logs` — `kamal app logs [--follow] --lines N`

Constructor injection: `kamal:` and `doctor:` kwargs accepted for test doubles.

### Commands::Doctor — pre-deploy checklist

`doctor.rb` runs 8 checks in two groups. Returns `true` / `false`; prints `✓` / `✗` per check.

| Option | Effect |
|--------|--------|
| `fast: true` | Local-file checks only (1–4); no shell-outs — used by deploy pre-flight |
| `quiet: true` | Suppresses all output — used by deploy pre-flight |
| `validate: true` | Adds check 8 (HTTP call to gateway) |

Checks:

1. `config/deploy.yml` exists
2. `.kamal/secrets` has all required keys set to non-empty values (rejects `KEY=""`)
3. Licence key configured via `AuthStore`
4. `.gitignore` contains `auth.json`, `.env`, `.kamal/secrets`
5. Docker is running (`docker info`)
6. Kamal config is valid (`kamal config`)
7. Licence key not in git history (`git log -S <key>`)
8. Licence key valid via gateway (HTTP Basic to `gateway.octobercms.com`)

Required secret keys for check 2: `KAMAL_REGISTRY_PASSWORD`, `OCTOBER_LICENCE_KEY`, `APP_KEY`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`.

### Services::Kamal — tty-command wrapper

`kamal.rb` wraps all `kamal` invocations. Constructor takes `project_dir:`, `licence_key:`, `output:` (tty-command printer, default `:pretty`), and `cmd:` (for injection in tests).

- `run(*args)` — runs `kamal <args>`; raises `Kamal::Error` on non-zero exit
- `run!(*args)` — same but raises `Thor::Error` (user-facing) instead
- `Kamal::Error` — inner class of `Services::Kamal`
- Redacts the licence key from all exception messages via `str.gsub(@redact, "[REDACTED]")`

### Commands::Init — plain Ruby class pattern

`init.rb` is a plain Ruby class (not a Thor subclass) with `initialize(options={})` and `call`. It is registered directly as a method on `CLI < Thor`:

```ruby
def init
  Commands::Init.new(skip_existing: options[:skip_existing]).call
end
```

This eliminates Thor's `subcommand + default_task` pattern and the associated test noise. `Thor::Error` is still raised for user-facing errors since `CLI` catches it.

### octobercms init — what it does

1. Detects `composer.json` + `artisan` in cwd (errors if absent)
2. Resolves licence key via `AuthStore` — prompts for copy/setup if needed
3. Prompts: app name, registry, image, server IPs, domain, database type
4. Generates 6 files (create/skip/overwrite with prompts):
   - `Dockerfile`, `config/deploy.yml`, `.kamal/secrets`, `.env.example`
   - `.gitignore` (append-only), `.dockerignore` (append-only)

`--skip-existing` skips existing files without prompting.

### auth_store.rb — credential resolution order

1. `OCTOBER_LICENCE_KEY` environment variable (highest priority, CI/operator)
2. `OCTOBER_LICENCE_KEY` in `.kamal/secrets` (per-project key)
3. `~/.config/octobercms/auth.yml` (global default, `licence_key:` key)

`AuthStore.resolve(project_dir:)` returns `{key: String, source: :env | :project | :global}` or `nil`.

File writes are atomic: write to `.tmp` → `chmod 0600` → rename. Keys in `.kamal/secrets` are stored quoted: `OCTOBER_LICENCE_KEY="value"`. Reader strips surrounding quotes for backward compatibility.

### validate_key — how it works

`auth setup` and `auth status --validate` hit `https://gateway.octobercms.com/packages.json` with HTTP Basic auth (username: `octobercms`, password: licence key). `200` → valid, `401` → rejected, other → unexpected. The licence key is redacted from all output.

### Key gem dependencies

- **Thor** (`~> 1.3`) — command tree; `raise Thor::Error` for user-facing errors; `Commands::Init` is a plain Ruby class registered on `CLI`, not a Thor subclass
- **tty-prompt** (`~> 0.23`) — masked key input, yes/no confirms, select menus
- **tty-command** (`~> 0.10`) — shells out to `kamal`; streams output; used by `Services::Kamal`
- **kamal** (`~> 2.0`) — deploy engine; invoked via tty-command shell-out (never `require "kamal"`)
- **Net::HTTP** (stdlib) — gateway validation; no extra HTTP gem dependency

### Running gem tests

```sh
bundle exec rspec spec/unit/auth_store_spec.rb
bundle exec rspec spec/unit/auth_commands_spec.rb
bundle exec rspec spec/unit/init_command_spec.rb
bundle exec rspec spec/unit/deploy_command_spec.rb
bundle exec rspec spec/unit/doctor_command_spec.rb
bundle exec rspec spec/unit/services/kamal_spec.rb
bundle exec rspec spec/unit/generators/
bundle exec rspec --tag '~integration'  # all unit tests (204 examples)
```

## M5+ planned additions

```
lib/octobercms/commands/
  plugin.rb / backup.rb
lib/octobercms/services/
  composer.rb / docker.rb / api_client.rb
```

Commands are thin (parsing, prompting, dispatching). Logic lives in services and generators.

## Architecture: how deploy works

`octobercms deploy` pipeline (run inside the user's OctoberCMS project repo):

1. **Pre-flight** — `Doctor` (fast + quiet mode) checks local files only: `config/deploy.yml`, `.kamal/secrets`, licence key, `.gitignore`. Failures print a single message directing the user to `octobercms doctor`.
2. **Build + push** — `kamal build push`. Kamal reads `OCTOBER_LICENCE_KEY` from `.kamal/secrets` and passes it to `docker build` as a BuildKit secret; the generated `Dockerfile` uses it via `COMPOSER_AUTH` during `composer install` only — never enters image layers.
3. **Migrate** — `kamal app exec --reuse 'php artisan october:migrate'` runs in the **existing** container before rolling restart.
4. **Deploy** — `kamal deploy` (rolling restart via `/up` health check). Note: `kamal deploy` also builds; Docker layer cache makes the re-build fast after step 2. A skip-build variant will replace this once the correct Kamal 2.x flag is confirmed in M5.

Each step is its own subcommand for debugging: `octobercms build`, `octobercms migrate`. Pass `--skip-migrate` to `deploy` to skip step 3.

## Architecture: authentication and secrets

**Account auth (OAuth browser flow):**
- `octobercms auth login` opens browser to `https://octobercms.com/cli/authorize?code=<random>`, local HTTP listener captures callback token
- Token stored at `~/.config/octobercms/auth.yml` (mode `0600`)
- CI uses `OCTOBER_API_TOKEN` env var instead
- Token grants read access to Project Licences only; never logged or displayed

**Licence credential flow (M3 implementation):**
- `init` asks for the licence key and stores it in `.kamal/secrets` (mode `0600`, gitignored) as `OCTOBER_LICENCE_KEY="value"`
- `config/deploy.yml` references it under `builder.secrets`; Kamal passes it to `docker build` as a BuildKit secret
- The generated `Dockerfile` reads it via `COMPOSER_AUTH` env var during `composer install` only — it never enters image layers or the running container
- Runtime container has no licence credentials

_Planned (M5+): the CLI will fetch the licence key from the OctoberCMS API at build time using an account token (OAuth flow), eliminating manual key entry._

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
