# OctoberCMS CLI Installer — Design Document

## Background and motivation

OctoberCMS faces the same problem as every mid-tier self-hosted CMS: developers who would otherwise pick it bounce off the deployment friction. Provisioning a server, configuring PHP-FPM and Nginx, setting up MySQL, wiring up TLS, and running migrations is a meaningful barrier compared to "click signup" on a SaaS competitor. A great deployment experience is a strategic lever: it improves conversion of evaluators, lowers churn from existing self-hosters, and lays the foundation for a future managed hosting product without committing to that scope today.

This document describes a Ruby-based CLI installer plus an official Docker image that, together, make deploying OctoberCMS a one-command operation against any Linux server. It builds on Kamal as the deployment engine — Kamal solves the hard parts (rolling deploys, kamal-proxy with Let's Encrypt TLS, health checks, secrets management, registry handling) and our gem adds OctoberCMS-aware scaffolding, lifecycle commands, and ecosystem integration.

The strategic frame: this is Phase 1 of a multi-phase plan. The CLI ships value to every existing and prospective OctoberCMS user, generates real telemetry about how OctoberCMS is deployed in production, and produces deployment primitives (the Docker image, the deploy.yml shape, plugin management logic) that a hosted platform can later reuse. We explicitly do not commit to building the hosted platform as part of this design — that decision is made on the strength of CLI adoption and the clarity of the funding case.

## Goals and non-goals

### Goals

- A developer with a Linux server, a domain, and Ruby installed can deploy a production OctoberCMS site in under 15 minutes.
- Subsequent deploys complete in under 90 seconds with zero downtime.
- The deployment is reproducible: the same project on a fresh server produces an identical site.
- Self-hosters and agencies are first-class users; the design does not assume a hosted platform is coming.
- The Docker image and deploy.yml shape are reusable as the foundation for a future managed hosting product, but no part of v1 or v2 depends on that product existing.

### Non-goals

- Replacing the OctoberCMS admin UI for plugin and theme management. The CLI manages installation; in-app configuration remains the admin's job.
- Becoming a general-purpose PHP application deployer. Every design decision is allowed to be OctoberCMS-specific.
- Supporting non-Linux deployment targets. macOS and Linux are first-class for the developer's machine; deployment targets are Linux only.
- Supporting OctoberCMS versions older than the current stable release.

## Architecture overview

Three artifacts together form the product:

1. **`octobercms/octobercms` Docker image** — the deployable unit. Owned by the platform team, versioned with OctoberCMS releases, immutable per tag.
2. **`octobercms` Ruby gem** — the developer-facing CLI. Wraps Kamal with OctoberCMS-aware defaults, scaffolding, and lifecycle commands.
3. **Deploy template repo** — what `octobercms init` generates in the customer's project directory. Lives in version control alongside the gem; rendered through ERB at init time.

The CLI is a thin orchestrator. Kamal does the actual deployment work. Our gem's job is to make Kamal pleasant for the OctoberCMS-specific case: scaffold sensible config, manage Composer-based plugins, handle migrations correctly, take backups, and surface health checks that actually understand OctoberCMS.

```
┌─────────────────────────────────────────────────────────────┐
│  Developer's machine                                        │
│  ┌──────────────────┐                                       │
│  │  octobercms CLI  │ shells out to                         │
│  │  (Ruby gem)      │ ──────────► kamal CLI ──┐             │
│  └──────────────────┘                          │             │
│         │                                       │             │
│         │ generates                             │             │
│         ▼                                       │             │
│  ┌──────────────────┐                          │             │
│  │  Project files   │                          │             │
│  │  - Dockerfile    │                          │             │
│  │  - deploy.yml    │                          │             │
│  │  - composer.json │                          │             │
│  │  - .env          │                          │             │
│  └──────────────────┘                          │             │
└────────────────────────────────────────────────┼─────────────┘
                                                  │
                                                  ▼ SSH
┌─────────────────────────────────────────────────────────────┐
│  Customer's server (Linux + Docker)                         │
│  ┌──────────────────┐    ┌──────────────────┐               │
│  │  kamal-proxy     │───►│  app container    │               │
│  │  (TLS, routing)  │    │  octobercms image │               │
│  └──────────────────┘    │  + storage volume │               │
│                          └────────┬─────────┘               │
│                                   │                          │
│                          ┌────────▼─────────┐               │
│                          │  MySQL accessory  │               │
│                          │  (or external DB) │               │
│                          └──────────────────┘               │
└─────────────────────────────────────────────────────────────┘
```

## Component design

### The Docker image

The image is the foundation and the longest-lived commitment in the system. Once published, its volume contract and environment variable schema are part of the public API.

#### Process model

PHP-FPM and Nginx run in a single container, supervised by **s6-overlay**. s6-overlay is the modern standard for multi-process containers, handles signal propagation correctly, and produces clean shutdown semantics. We deliberately avoid supervisord because of long-standing PID 1 signal handling issues that bite during rolling deploys.

A single-container model is the right choice for the self-hoster CLI. Two containers (php-fpm + nginx sharing a network) is more "correct" by twelve-factor standards but adds friction to Kamal's mental model of one container per role. We can revisit a split-container model when we build the hosted platform if benchmarks justify it.

#### Volume contract

One required persistent volume and two optional ones:

- `/app/storage` — uploads, generated thumbs, logs, cache, sessions. Everything user-generated and writable. **Required.**
- `/app/plugins` — writable by `www-data` for admin UI plugin installation. Mount as a volume if you want admin-installed plugins to survive redeployments.
- `/app/themes` — writable by `www-data` for admin UI theme installation. Mount as a volume if you want admin-installed themes to survive redeployments.

Everything else — core code, vendor, config — is immutable in the image. This breaks from traditional OctoberCMS installs where everything is one writable directory, and the break is intentional. Atomic deploys, testable images, and clean rollbacks all depend on it.

The volume contract is part of the public API of the image. Changes to it require a major version bump and a documented migration path.

#### Configuration

The image reads all runtime configuration from environment variables. An entrypoint script renders `config/*.php` from ERB-style templates on container start. Documented variables:

| Variable | Required | Example | Notes |
|---|---|---|---|
| `APP_KEY` | yes | `base64:...` | OctoberCMS encryption key |
| `APP_URL` | yes | `https://example.com` | |
| `APP_ENV` | no | `production` | Defaults to `production` |
| `DB_CONNECTION` | yes | `mysql` | |
| `DB_HOST` | yes | `mysql` | |
| `DB_PORT` | no | `3306` | |
| `DB_DATABASE` | yes | `october` | |
| `DB_USERNAME` | yes | `october` | |
| `DB_PASSWORD` | yes | (secret) | |
| `STORAGE_DRIVER` | no | `local` | `local`, `s3`, `r2` (v2) |
| `S3_*` | no | | Required only when `STORAGE_DRIVER=s3` |

OctoberCMS Project License credentials are deliberately **not** runtime variables. The CLI fetches licence keys at build time via the OctoberCMS API (using the customer's account token from `~/.config/octobercms/auth.yml`) and passes them to the build via Docker BuildKit secret mounts so they never appear in image layers. The customer never pastes a Project ID or licence key into the CLI. See the OctoberCMS licensing section below for the full design.

#### Health check

A `/up` endpoint returns 200 only when:
- PHP-FPM is responsive
- The configured database is reachable
- The migrations table exists

This mirrors Rails 7+ convention. Without a real health check, Kamal's "rolling deploy" is just a restart with hopeful timing. The endpoint is defined in a small custom OctoberCMS plugin shipped with the image, not a static file, so it can do real work.

#### Image versioning

Tags encode the PHP version, not the OctoberCMS version. OctoberCMS version is determined by the user's own `composer.json` in their derived image.

- `ghcr.io/antgeo/octobercms:php8.3` (specific PHP version)
- `ghcr.io/antgeo/octobercms:latest` (latest published runtime)

We commit to:
- A new tag per supported PHP version (e.g. `php8.4` when that ships)
- Security patches within 72 hours of upstream Alpine/PHP release
- The volume contract and env var schema are permanent public API — changes require a major version bump

#### Plugin and theme installation strategy

Two viable approaches; we ship one as primary and one as escape hatch.

**Build-time (primary).** Customer's derived `Dockerfile` (generated by the CLI) runs `composer require` for plugins. Image is rebuilt on every plugin change. This is Kamal-native, matches the immutability model, and produces atomic rollbacks. The CLI's `octobercms plugin add` command edits `composer.json` and triggers a redeploy — the customer never sees the Dockerfile mechanics.

**Runtime (escape hatch).** Plugins live in a mounted volume and can be installed through the OctoberCMS admin UI. Documented for users who need it; not the default. Trades immutability for familiarity.

The strategic implication of build-time as primary: the **plugin distribution path is Composer**. Plugins not on Packagist need to be added via local paths (a `plugins/` directory in the project that's COPYed into the image at build) or via custom Composer repositories. We ship a curated index of the top OctoberCMS plugins mapping friendly names to Packagist packages, falling back to direct Packagist lookup for anything not in the index. v2 may add a private Packagist (`satis`) for the platform-blessed plugin set.

#### Dockerfile

The runtime image is a single-stage build — no OctoberCMS code is included. Users build a derived image on top of it:

```dockerfile
# Runtime image (this repo — ghcr.io/antgeo/octobercms:php8.3)
FROM php:8.3-fpm-alpine
# PHP extensions, Nginx, s6-overlay, crond — no application code

# User's derived image (their OctoberCMS project repo — generated by `octobercms init`)
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

The licence key is passed as the `OCTOBER_LICENCE_KEY` BuildKit secret (mounted from `.kamal/secrets` by Kamal via `builder.secrets` in `config/deploy.yml`). `COMPOSER_AUTH` injects it as an HTTP Basic credential for the OctoberCMS gateway only during `composer install` — it never enters any image layer. This is verified in CI by inspecting `docker history`.

_Note: the current implementation (M3) requires the user to supply their licence key via `octobercms auth setup`. A future milestone (M5+) will replace this with an OAuth flow that fetches the key from the OctoberCMS API automatically at build time, eliminating manual key entry entirely._

The `docker/rootfs/` directory in this repo contains s6 service definitions, nginx config, php-fpm config, opcache config, and the generate-env entrypoint script.

### The Ruby gem

#### Gem structure

```
octobercms/
  bin/
    octobercms                  # entrypoint
  lib/
    octobercms/
      cli.rb                    # Thor command tree
      version.rb
      config.rb                 # Project config loader
      commands/
        init.rb                 # Scaffold a new project
        deploy.rb               # Wraps `kamal deploy`
        plugin.rb               # add/remove/list
        theme.rb                # (v2)
        backup.rb               # DB + storage backup
        restore.rb              # Restore from backup
        console.rb              # `kamal app exec --interactive`
        logs.rb                 # `kamal app logs`
        doctor.rb               # Pre-flight environment checks
        upgrade.rb              # (v2) OctoberCMS version bumps
        auth/
          login.rb              # Browser OAuth flow
          logout.rb             # Delete local token
          status.rb             # Show logged-in account, projects, licences
          refresh.rb            # Rotate token
        project/
          list.rb               # List Projects in the account
          select.rb             # Switch project for current directory
          create.rb              # Create a new Project via API
      generators/
        dockerfile.rb
        deploy_yml.rb
        env.rb
        composer_json.rb
        auth_json.rb             # Generates temp auth.json for build-time mount
        gitignore.rb              # Ensures auth.json/.env/.kamal/secrets are excluded
        project_file.rb           # Generates .kamal/project (committable)
      services/
        kamal.rb                # tty-command wrapper around kamal
        composer.rb             # composer.json/lock manipulation
        docker.rb               # local docker operations + BuildKit secret handling
        backup_engine.rb        # mysqldump + storage tar
        plugin_index.rb         # curated plugin → Packagist mapping
        api_client.rb           # OctoberCMS account API client
        auth_store.rb           # ~/.config/octobercms/auth.yml read/write
        oauth_listener.rb       # Local HTTP listener for OAuth callback
        license.rb              # Licence resolution, validation, redaction
      templates/                # ERB templates
        Dockerfile.erb
        deploy.yml.erb
        secrets.erb
        env.example.erb
        composer.json.erb
        auth.json.erb
        gitignore.erb
        project.erb
  test/
    ...
```

The structure follows Rails conventions because that's the muscle memory of the engineer building it. Commands are thin (parsing, prompting, dispatching); logic lives in services and generators. Generators use ERB templates that live in `lib/octobercms/templates/`; output is deterministic and diffable.

#### Dependency choices

- **Thor** for the command tree — what Rails CLI and Kamal both use, well-trodden, easy to maintain.
- **TTY toolkit** (`tty-prompt`, `tty-spinner`, `tty-command`, `tty-logger`) for interactive prompts, progress feedback, and shell-out — the standard for serious Ruby CLIs.
- **dotenv** for `.env` parsing.
- **HTTP** (`faraday` or `http.rb`) for Packagist lookups in the plugin index.

We deliberately avoid:

- ActiveRecord, Sequel, or any ORM. The CLI reads and writes flat files; no schema needed.
- Sidekiq, Resque. No background processing; everything is synchronous.
- Bundler-managed runtime dependencies beyond the gem's own. Keep the install footprint small.

Ruby version requirement: 3.2+. We commit to supporting the two latest stable Ruby versions.

#### The init flow

The interactive `init` flow is where the UX is won or lost. The first thirty seconds set the tone for the entire product.

```
$ octobercms init

Welcome! Let's set up a new OctoberCMS project.

Checking authentication... not logged in.

? Log in to your OctoberCMS account?
  > Yes — open browser to log in
    Use an existing API token instead
    Skip for now (some commands will be unavailable)

  Opening https://octobercms.com/cli/authorize... ✓
  Waiting for you to complete login in your browser...
  ✓ Logged in as anthony@example.com

? Project name: my-october-site
? Primary domain: example.com
? Server (or 'local' for development): web1.example.com
? Database:
  > MySQL on the same server (recommended for getting started)
    External managed MySQL (PlanetScale, Aiven, etc.)
    Existing MySQL server
? Object storage:
  > Local filesystem (default)
    Cloudflare R2     [v2]
    AWS S3            [v2]
? Container registry:
  > GitHub Container Registry (ghcr.io)
    Docker Hub
    Custom

Fetching your OctoberCMS Projects from your account...

? Which Project should this site use?
  > example.com (Regular License, expires 2027-04-12) — unused
    client-portfolio (Extended License, covers 12 sites)
    + Create a new Project (free first-year licence available)

  Selected: example.com

Generating project...
  ✓ Dockerfile (with BuildKit secret mount for Composer auth)
  ✓ config/deploy.yml
  ✓ .kamal/project (Project ID: ABC123 — safe to commit)
  ✓ .kamal/secrets (gitignored — contains DB_PASSWORD, etc.)
  ✓ .env.example
  ✓ composer.json (with octobercms/october pinned to 3.5)
  ✓ .gitignore (excludes auth.json, .env, .kamal/secrets)

Next steps:
  1. cd my-october-site
  2. cp .env.example .env  (and edit secrets)
  3. octobercms doctor       (validates your environment and licence)
  4. octobercms deploy
```

A few notable properties of this flow:

- **Auth happens once per machine.** Subsequent `octobercms init` runs in other directories skip the auth step entirely.
- **The Project picker shows licence health inline.** Customers see expiry dates and licence type at the moment they're choosing — no need to mentally cross-reference with the OctoberCMS account portal.
- **Creating a Project is inline.** "Create a new Project" calls the OctoberCMS API to create one (using the free-licence default for new accounts), then proceeds. This is the single biggest UX improvement over manual credential paste — first-time users go from "I have an account" to "I'm deploying" without ever leaving the CLI.
- **`.kamal/project` is safe to commit.** It contains only the Project ID, not the licence key. This means the CLI can resolve the Project ID across team members without each one re-running `init`.
- **No licence key is ever displayed or persisted in the project.** The CLI knows how to fetch it from the API at build time using the account token.

Power users can override every default with flags (`octobercms init --db external --registry dockerhub --project ABC123`) for non-interactive use.

#### The deploy lifecycle

`octobercms deploy` runs:

1. **Pre-flight.** Fast subset of `doctor` checks. Validate that `composer.lock` matches `composer.json`. Check for uncommitted changes (warn, don't block). Verify the customer is authenticated (account token present and valid) and has licence access for the configured Project.
2. **Build.** Kamal reads `OCTOBER_LICENCE_KEY` from `.kamal/secrets` and passes it to `docker build` as a BuildKit secret (via `builder.secrets` in `config/deploy.yml`); the generated `Dockerfile` injects it via `COMPOSER_AUTH` during `composer install` only — it never enters image layers or logged output. _(Full design: the CLI fetches the key from the OctoberCMS API per-build using the stored account token, eliminating the key from `.kamal/secrets`. This API integration is planned for M5+.)_
3. **Push.** `kamal registry login && docker push`.
4. **Migrations.** Run `php artisan october:migrate` in a one-shot container against the production DB, before the rolling deploy. This is critical — running migrations during a rolling deploy causes race conditions when multiple app instances exist or when health checks fail mid-migration.
5. **Deploy.** `kamal deploy`. Kamal handles the rolling restart and kamal-proxy drains old containers based on the `/up` health check.
6. **Post-deploy.** Clear OctoberCMS cache (`php artisan cache:clear`) inside the new container. Optionally warm critical routes via configured health probe URLs.

Each step has its own subcommand for debugging (`octobercms migrate`, `octobercms build`, `octobercms push`). The composed `octobercms deploy` is what users run day-to-day.

The CLI never logs, echoes, or prints the licence key or account token under any circumstance — including in `--verbose` mode. Build output that would normally include Composer auth chatter is filtered to redact any string matching the credential format if it ever appears.

#### The doctor command

`doctor` is the most underrated command in the product. Its job is to catch every environmental issue that would otherwise turn into a support ticket.

Checks performed:

- SSH access to all configured servers (with informative error if key not loaded)
- Docker installed on each server (and version is sane, BuildKit-capable, 20.10+)
- Docker daemon running and current user can talk to it
- Container registry login works
- DNS for the configured domain points to a configured server
- Ports 80 and 443 are open from the public internet
- `.env` and `.kamal/secrets` exist and contain non-placeholder values
- OctoberCMS account token is present (`~/.config/octobercms/auth.yml` or `OCTOBER_API_TOKEN` env var) and validates against the API
- The configured Project ID (`.kamal/project`) exists in the customer's account and has an active licence
- Licence expiry: warn at 30 days remaining, error at expired
- Update Gateway round-trip: API auth produces a working Composer credential by performing a HEAD against the Gateway with the resolved licence key
- `auth.json` is in `.gitignore` (and not present in git history)
- `.env` and `.kamal/secrets` are in `.gitignore` (and not present in git history)
- Git history grep for any string matching the OctoberCMS licence key format (catches accidental commits from before the CLI was adopted)
- `composer.lock` matches `composer.json`
- Sufficient disk space on target servers (warn at <5GB free)
- System time is within 5s of NTP (Let's Encrypt fails on bad clocks)

Every support ticket where the root cause turns out to be environmental becomes a new doctor check. Treat doctor as the support team's first line of defence and the CLI's most important regression test.

#### Plugin management

```
$ octobercms plugin add rainlab.user
  Looking up rainlab.user in the curated index...
  ✓ Found: rainlab/user @ ^1.6
  ✓ Added to composer.json
  ✓ Updated composer.lock (1 package added, 0 removed)
  
  Run `octobercms deploy` to apply changes.
```

Implementation:

- The plugin index is a YAML file shipped with the gem mapping friendly names (`rainlab.user`) to Composer packages (`rainlab/user`). For plugins not in the index, `octobercms plugin add <packagist-name>` accepts a raw Composer name.
- Local-path plugins live in a `plugins/` directory and are detected automatically. The Dockerfile COPYs `plugins/` into the image at build.
- `octobercms plugin list` reads `composer.json` and `composer.lock` and presents installed plugins with their resolved versions.
- `octobercms plugin remove` is the inverse of add.

We do not at v1 attempt to manage plugin configuration — that remains the OctoberCMS admin UI's job. Installation only.

#### Backups

`octobercms backup`:

1. Runs `mysqldump` inside a one-shot container connected to the production database. Dump is streamed to a local temp file, gzipped.
2. Tars `/app/storage` from a one-shot container with the storage volume mounted read-only. Streamed and gzipped.
3. Combines the two into a single archive with a manifest JSON describing OctoberCMS version, plugin versions, schema version, and timestamp.
4. Writes the archive to a configurable destination: local path, S3 URL, or R2 URL (v2).

`octobercms restore <backup-id>`:

1. Confirms destructively (interactive prompt; `--yes` flag for automation).
2. Stops the app container.
3. Restores the database from the manifest.
4. Restores the storage volume from the manifest.
5. Starts the app container and runs migrations to ensure schema matches current code.

v1 is manual only. v2 adds scheduling, retention policies, and managed off-site storage targets.

### The deploy.yml template

What `octobercms init` generates:

```yaml
service: my-october-site
image: my-org/my-october-site

servers:
  web:
    - web1.example.com

proxy:
  ssl: true
  host: example.com
  app_port: 80
  healthcheck:
    path: /up
    interval: 5

registry:
  server: ghcr.io
  username: my-org
  password:
    - KAMAL_REGISTRY_PASSWORD

env:
  clear:
    APP_ENV: production
    APP_URL: https://example.com
    DB_CONNECTION: mysql
    DB_HOST: mysql
    DB_DATABASE: october
    STORAGE_DRIVER: local
  secret:
    - APP_KEY
    - DB_PASSWORD

volumes:
  - "october_storage:/app/storage"

accessories:
  mysql:
    image: mysql:8.0
    host: web1.example.com
    port: "127.0.0.1:3306:3306"
    env:
      clear:
        MYSQL_DATABASE: october
      secret:
        - MYSQL_ROOT_PASSWORD
        - MYSQL_PASSWORD
    volumes:
      - "/var/lib/mysql-october:/var/lib/mysql"
```

Two notable choices:

- **kamal-proxy handles TLS.** Kamal 2.x ships with kamal-proxy (replaced Traefik), which does Let's Encrypt automatically. One less moving part.
- **MySQL as a Kamal accessory** is fine for single-server setups. The CLI's `--db external` flag generates config that points at managed MySQL providers instead and omits the accessory block.

The generated config is hand-editable. Customers will modify `deploy.yml` directly for advanced scenarios (multiple servers, custom networks, additional accessories like Redis). The CLI's generators detect existing files and prompt or merge rather than clobbering.

## v2 design

v2 layers additional capabilities on the v1 foundation. None of v2 changes the v1 interfaces — every v2 addition is backwards-compatible.

### Multiple PHP versions

Ship `octobercms:3.5-php8.2` alongside `octobercms:3.5-php8.3`. CLI gains a `--php-version` flag at init time. The Dockerfile generator produces the correct `FROM` line. Doctor warns when the configured PHP version is approaching end-of-life.

### Theme management

Mirror the plugin command tree:

```
octobercms theme add <name>
octobercms theme remove <name>
octobercms theme list
octobercms theme set-active <name>
```

Themes are managed via Composer where possible, with a `themes/` directory escape hatch for local themes. The `set-active` command updates `cms.activeTheme` in the configuration via the OctoberCMS CLI inside the container.

### Object storage integration

CLI gains first-class support for Cloudflare R2 and AWS S3 as storage drivers:

```
octobercms storage configure r2
  ? R2 account ID: ...
  ? R2 access key ID: ...
  ? R2 secret access key: (hidden)
  ? Bucket name: my-site-uploads
  
  ✓ Updated .env with STORAGE_DRIVER=r2 and S3_* variables
  ✓ Added rainlab/builder-storage-driver to composer.json
  
  Run `octobercms deploy` to apply.
```

The Docker image supports `STORAGE_DRIVER=r2` natively from v2 onwards. The customer's local storage is migrated to the configured bucket via an `octobercms storage migrate` command that runs a one-shot container.

### Scheduled backups

`octobercms backup schedule install` writes a systemd timer (or cron entry as fallback) on the configured server that runs `octobercms backup` on a configurable schedule with retention policies:

```
octobercms backup schedule install \
  --frequency daily \
  --retain "7 daily, 4 weekly, 12 monthly" \
  --destination s3://my-backups/
```

The schedule lives on the server, not on the developer's machine — so backups continue even when the developer is offline. Retention policies are enforced by a small pruning command run as part of each backup.

### `octobercms upgrade`

A guided OctoberCMS version bump:

1. Detects current OctoberCMS version from `composer.json`.
2. Looks up the upgrade path (e.g., 3.4 → 3.5 → 3.6).
3. Runs each step: update `composer.json`, run `composer update`, run a dry-run migration in a one-shot container, prompt the user to review.
4. If approved, runs `octobercms backup` automatically (defensive), then deploys, then runs migrations.
5. Provides a clear rollback path via `octobercms restore` against the auto-backup.

This is the most-requested operational task in mid-tier CMSes and the one most often done badly. Worth real design effort in v2.

### Multi-server deploys

v1 supports multi-server via raw Kamal config (the customer edits `deploy.yml`). v2 makes it first-class:

- `octobercms server add <hostname>` and `octobercms server remove <hostname>` manage the server list.
- Doctor checks run against all configured servers.
- Deployment shows per-server progress.
- A shared MySQL deployment story (managed external DB only — running MySQL on multiple app servers is not supported).

### Staging environments

`octobercms env add staging` creates a parallel Kamal destination with a `-staging` suffix on the service name and a separate domain. The same Dockerfile, deploy.yml, and plugin set are used; only secrets and the `.env` differ. `octobercms deploy --env staging` deploys to staging; `octobercms deploy` defaults to production.

### Plugin marketplace integration

The CLI integrates with an OctoberCMS-run plugin marketplace:

- `octobercms plugin search <term>` searches the marketplace index.
- `octobercms plugin add <name>` resolves marketplace plugins via a private Packagist (`satis`) hosted by OctoberCMS, with license enforcement at install time.
- Premium plugins authenticate via an OctoberCMS account credential stored in `.kamal/secrets`.

This is where revenue beyond the core license can flow. The marketplace is a mid-2026 strategic initiative in its own right; the CLI's job is to be the distribution chokepoint for paid plugins.

### Self-contained binary distribution

For developers without Ruby installed, ship a self-contained binary built with `ruby-packer` or similar. Distributed via Homebrew, a Linux package repo, and direct download. v1 requires Ruby; v2 removes that requirement.

## OctoberCMS licensing

How the OctoberCMS Project License flows through the CLI is one of the most architecturally consequential decisions in this design. It determines how secrets are handled, what the build looks like, and what the customer's first-run experience feels like. This section captures the full design.

### How OctoberCMS licensing actually works

OctoberCMS licensing is **per-website**, not per-platform. Every site deployed with this CLI requires its own Project License from the customer's OctoberCMS account. The CLI is a deployment tool, not a licence redistribution mechanism — we do not relicense OctoberCMS to end users, and nothing about this design changes the existing licensing relationship between the customer and OctoberCMS.

A few facts about the licensing model that drive the design:

- The platform source code is on GitHub and is not compiled or encrypted, but a licence is required to run OctoberCMS in production. The licence grants the right to use one copy for a single website (with `dev.example.com` and `staging.example.com` covered by the same Project License as `example.com`).
- Licences are perpetual. Non-renewal removes access to the Update Gateway, but the deployed website continues to run indefinitely.
- Every new OctoberCMS account includes a complimentary licence for the first project, with full features for the first year. This is the canonical evaluation path and the CLI must make it frictionless.
- Composer is the primary install/update mechanism. The licence is essentially a Composer auth credential against the OctoberCMS Update Gateway (a private Composer repository).
- The licence is required only at *build time* (when fetching packages from the Update Gateway), not at runtime. The deployed container never sees the licence credentials.

These facts drive two architectural choices: licence credentials are a build-time concern only (so they go through Docker BuildKit secret mounts), and the CLI integrates directly with the customer's OctoberCMS account via API (so the customer never pastes a credential into the CLI). The second choice is the bigger lift, but it pays for itself within the first agency customer with five sites.

### Authentication model: account login, not credential paste

v1 uses an OAuth-style browser flow for the customer to authenticate with their OctoberCMS account, modelled directly on `gh auth login` and `flyctl auth login`. The customer never pastes a Project ID or licence key into the CLI — the CLI fetches credentials on their behalf via the OctoberCMS API.

This is a deliberate v1 choice rather than a v2 enhancement. The reasoning:

- **The CLI is built by the platform owner.** Coordinating the API surface across both products is a one-organisation problem, not a two-organisation negotiation. There is no external dependency that would justify deferring the API integration.
- **Manual credential paste is a recurring source of support tickets** in every CMS that uses it. Mistyped Project IDs, expired licences not noticed until a build fails, credentials accidentally committed — all disappear when the CLI talks to the account directly.
- **Multi-project workflows are the common case.** Agencies running 10+ client sites do not want to copy-paste credentials into 10+ project directories. A single `octobercms auth login` covers their whole portfolio.
- **The OAuth pattern is well-trodden.** `gh`, `flyctl`, `wrangler`, `supabase`, and `gcloud` all do essentially the same thing. The implementation cost is real but bounded — roughly 1-2 weeks of focused work, well within v1 scope.

The auth flow:

1. `octobercms auth login` opens the customer's browser to `https://octobercms.com/cli/authorize?code=<random>` and starts a local HTTP listener on a random port.
2. The customer logs in to their OctoberCMS account if not already logged in, reviews the requested permissions ("read your Project Licenses"), and approves.
3. The OctoberCMS site redirects back to `http://localhost:<port>/callback?token=<long-lived-token>`.
4. The CLI captures the token, closes the listener, and writes it to `~/.config/octobercms/auth.yml` (Linux/macOS) or `%APPDATA%/octobercms/auth.yml` (Windows, deferred to v2). File permissions are set to `0600`.
5. The browser displays "You can close this tab and return to the CLI."

The token is a long-lived API token scoped to read-only access of the account's Project Licenses. It is **not** a session token — losing it does not log the customer out of their browser session. Token revocation is available in the OctoberCMS account portal.

For environments where browser auth isn't possible (CI, air-gapped, restricted networks), `octobercms auth login --token <token>` accepts a token generated manually from the account portal as a fallback. This is documented but not the default flow.

### Credential flow

The licence credentials move through the system as follows:

1. **Account auth.** Customer runs `octobercms auth login` once on their machine. The API token is stored in `~/.config/octobercms/auth.yml`. This is a one-time step.
2. **Init.** `octobercms init` prompts for deployment configuration (servers, registry, database, domain) and generates `Dockerfile`, `config/deploy.yml`, `.kamal/secrets`, `.env.example`, `.gitignore`, and `.dockerignore`. The licence key is stored in `.kamal/secrets`. _(Full design: the CLI will call the OctoberCMS API to present a Project picker and write only the Project ID to `.kamal/project`; the key is fetched per-build rather than stored.)_
3. **Build.** Kamal reads `OCTOBER_LICENCE_KEY` from `.kamal/secrets` and passes it to `docker build` as a BuildKit secret; the `Dockerfile` injects it via `COMPOSER_AUTH` during `composer install` only. The licence key never enters image layers or any logged output.
4. **Runtime.** The deployed container has no licence credentials. It serves the site with whatever package versions were resolved at build time. If the licence later expires, the running site is unaffected; only future builds would fail when attempting to fetch newer packages.

Two consequences of this design worth flagging:

- **The licence key is never persisted in the project directory.** It lives only in account state on the customer's machine and is fetched per-build. This eliminates a whole class of accidental-commit risks.
- **Builds require auth.** A build started without a valid account token (e.g. on a fresh CI runner without the secret configured) will fail with a clear "run `octobercms auth login` or set `OCTOBER_API_TOKEN`" message. CI pipelines store the token as an environment secret rather than running `auth login`.

### CI and machine accounts

CI environments use the same API but a different auth pattern:

- The customer creates a machine account token in the OctoberCMS account portal (a separate token type, scoped to specific Projects).
- The token is stored as a CI secret (`OCTOBER_API_TOKEN`) and exposed to the build environment.
- The CLI detects the env var and uses it directly, skipping the browser auth flow.
- Machine account tokens have explicit expiry dates and can be rotated independently of the human account.

This pattern matches `flyctl` (FLY_API_TOKEN) and `gh` (GH_TOKEN) and is well understood by anyone running these CLIs in CI.

### Why BuildKit secrets, not build args or env vars

Build args (`ARG`) and environment variables (`ENV`) are visible in `docker history` and persist in image layers — they are not safe for secrets. BuildKit secret mounts (`RUN --mount=type=secret`) are designed for exactly this case: the secret is mounted into the build container's filesystem only for the duration of a single `RUN` instruction, and is never written to any layer. CI verifies this property by inspecting `docker history` and grepping for any trace of the licence key after each official image build.

A secondary benefit: BuildKit secrets are not cached. A rebuild that would otherwise hit the build cache will still re-mount the secret correctly. This avoids a class of subtle bugs where a cached layer accidentally contains stale credentials.

### The auth.json question

Composer's traditional authentication mechanism is `auth.json` in the project root. We deliberately do **not** want this file checked in or persisted on the developer's machine in a place where it could leak. The CLI's approach:

- `octobercms init` writes `auth.json` to `.gitignore` along with `.env` and `.kamal/secrets`.
- The CLI never writes `auth.json` to disk in the project directory. It is generated as a temporary file in a secure temp directory only at build time and deleted immediately after.
- An `auth.json.example` is generated showing the structure (with placeholder values) so customers who need to authenticate Composer manually for IDE workflows know what shape to use, with a note that this file should never be checked in.

`doctor` greps git history for any string that looks like an OctoberCMS licence key (matching the documented format) and warns loudly if any matches are found, helping customers detect accidental commits even from before they were using the CLI.

### Licence visibility in the CLI

Because the CLI knows about the customer's account, it surfaces licence status proactively rather than reactively:

- `octobercms auth status` shows the logged-in account, available Projects, licence type per project (Regular vs Extended), and expiry dates.
- `octobercms doctor` includes a licence health check: warns at 30 days to expiry, errors at expiry, distinguishes "not authenticated" from "authenticated but no licence for this project" from "licence expired".
- `octobercms deploy` checks licence validity as part of pre-flight and refuses to start a build that would fail at the Composer auth step. Better to fail fast in pre-flight than 30 seconds into a Docker build.
- A pre-deploy banner in interactive use surfaces upcoming expiry dates: "Heads up — your licence for this project expires in 12 days. Renew at https://octobercms.com/account."

These touchpoints are only possible because the CLI is account-aware. Manual credential paste cannot offer them.

### Update Gateway validation

`doctor` validates the actual Composer auth path (in addition to the API-level licence check) by making an authenticated HTTPS HEAD request against the OctoberCMS Update Gateway with the resolved credentials. Distinct outcomes produce distinct error messages:

- **Not authenticated.** "You're not logged in to your OctoberCMS account. Run `octobercms auth login` to authenticate, or set `OCTOBER_API_TOKEN` for non-interactive use."
- **Authenticated but no licence for this project.** "Your account doesn't have a licence covering Project `<id>`. Run `octobercms init --reselect-project` to choose a different Project, or visit https://octobercms.com/account to acquire a licence."
- **Network unreachable.** "Could not reach the OctoberCMS Update Gateway. Check your network connection or proxy configuration."
- **Auth flow worked but Composer auth failed.** "The licence credentials returned by the API were rejected by the Update Gateway. This is unusual — please contact support with the output of `octobercms doctor --debug`."
- **Licence expired.** "Your licence for this project expired on <date>. The deployed website will continue to run, but new builds will fail until the licence is renewed. Visit https://octobercms.com/account to renew."

Specific, actionable error messages save more support time than any other doctor check.

### Multiple sites and the Extended License

OctoberCMS offers a Regular License (single site) and an Extended License (unlimited sites for the same person or organisation). The API-driven model handles both transparently:

- Each project directory references a Project ID via `.kamal/project`. The CLI fetches the appropriate licence key per build.
- For Extended Licence holders, the API simply returns the same licence key for any number of project lookups; the CLI doesn't need to know or care about the licence type.
- `octobercms auth status` displays each Project's licence type alongside expiry, so the customer can see at a glance which projects share a licence.

Agencies running 10+ client sites authenticate once on their machine, link each project directory to a different Project in their account, and never paste credentials. This is a meaningful UX improvement over the per-project credential paste model and is one of the strongest arguments for putting API integration in v1.

### Token storage and security

Account tokens are sensitive — they grant read access to the customer's Project list and licence keys. They live at:

- `~/.config/octobercms/auth.yml` (Linux, macOS) with file mode `0600`
- `%APPDATA%/octobercms/auth.yml` on Windows (v2 — Windows support is deferred from v1)

The CLI never logs the token, never includes it in `--verbose` output, and redacts any string matching the token pattern from error messages and crash reports. Token rotation is supported via `octobercms auth refresh` (rotates the token without requiring re-login) and `octobercms auth logout` (deletes the local token; revoke the token in the account portal to invalidate it server-side).

If a customer is on a multi-user system where `~/.config` permissions are inadequate, they can set `OCTOBER_API_TOKEN` per-shell-session as an alternative to file storage.

### What this design explicitly does not do

- **No licence enforcement on the CLI side.** The CLI does not check whether the customer's licence permits the number of projects they're running. The OctoberCMS API and Update Gateway handle enforcement; the CLI only handles authentication and credential fetching.
- **No licence purchase or renewal flow inside the CLI.** Buying, renewing, or upgrading a licence happens on the OctoberCMS website. The CLI points users there with deep links but does not embed payment flows.
- **No multi-account auth in v1.** v1 supports one logged-in account per machine. Customers who need to manage multiple OctoberCMS accounts (e.g. their own and a client's) use the `OCTOBER_API_TOKEN` env var override or a separate user profile. v2 may add `octobercms auth login --profile <name>` if this is requested often.
- **No token sharing across machines.** Each developer logs in on their own machine. Tokens are not designed to be copied between machines (though technically possible).
- **No telemetry beyond the auth flow.** The CLI's network communication with OctoberCMS infrastructure consists of (1) fetching licence keys via the API at build time, and (2) Composer auth against the Update Gateway during `composer install`. We do not track deployments, count builds, or report anything else.

## Security considerations

**Secrets handling.** Per-project secrets (database passwords, app keys) live in `.kamal/secrets` and are loaded via Kamal's secrets mechanism. The file is gitignored by default. Doctor warns if `.kamal/secrets` appears in git history. Runtime secrets are passed to the container via Kamal's secret env mechanism, never baked into the image. Build-time secrets (specifically the OctoberCMS licence credentials, fetched from the customer's account at build time) are passed via Docker BuildKit secret mounts and never enter image layers — see the OctoberCMS licensing section above for the full design.

**Account token storage.** The OctoberCMS account API token lives at `~/.config/octobercms/auth.yml` with file mode `0600`. The token is the gateway to fetching licence keys, so it is treated with care: never logged, never displayed in `--verbose` output, redacted from error messages and crash reports. Token rotation is supported via `octobercms auth refresh`; deletion via `octobercms auth logout`. For multi-user systems where filesystem permissions are inadequate, `OCTOBER_API_TOKEN` env var is supported as a per-shell-session alternative.

**Image supply chain.** The official image is built in CI from a signed source repository. Image tags are immutable. Image signatures are published via Docker Content Trust or `cosign`. Doctor verifies the image signature on first pull. CI inspects `docker history` of every published image and fails the build if any value matching the licence key pattern is present in any layer.

**SSH key handling.** The CLI uses the user's SSH agent; it never reads private keys directly. All operations against remote servers go through Kamal's SSH layer (which uses `net-ssh`).

**Database credentials.** Generated by the CLI at init time via `SecureRandom`, written to `.kamal/secrets`, and never displayed in CLI output beyond the initial generation. Rotation is documented but manual in v1.

**Update channel.** The CLI checks for new versions on each invocation (with a configurable opt-out). Updates are pulled from RubyGems via standard `gem update`. We do not auto-update; we surface the available version and let the user run the update.

## Strategic relationship to a future hosted platform

The hosted platform, if and when built, is a Rails control plane that runs `octobercms deploy` on the customer's behalf against servers we own. Concretely:

- The control plane provisions a Fly app per tenant (or equivalent compute primitive).
- The control plane generates the same `deploy.yml` the CLI generates, but with platform-managed servers and registry credentials.
- The control plane invokes Kamal (either by shell-out or by `require`-ing it) to deploy.
- The control plane reuses our gem's services — `Kamal`, `Composer`, `BackupEngine`, `PluginIndex` — verbatim.

Roughly 80% of the gem's code is reusable in the hosted platform. The CLI commands become the platform's internal API surface. This is the strategic payoff of building the CLI first: the hosted platform becomes a Rails wrapper around the CLI's services, not a separate codebase.

The CLI ships value standalone, so we are not committing to building the hosted platform. But every design decision in v1 and v2 is made with the hosted-platform reuse in mind — most notably the volume contract, the env var schema, the migration strategy, and the backup format.

## Open questions

**OctoberCMS API surface for v1.** The CLI's account integration assumes an API exposing: list Projects, fetch licence key for a Project ID, create a new Project, OAuth-style authorize endpoint with local callback. The exact API shape needs to be designed in coordination with the OctoberCMS web team. Open questions: does the API live under `octobercms.com/api/v1/` or a separate hostname; what's the rate limit posture (per-token, per-account); does it support pagination for accounts with hundreds of Projects; how are scopes represented on the token. None of these block v1 in principle but all need answering before M2 starts.

**Auth scope granularity.** The CLI needs read access to Project Licenses and (for "Create a new Project" inline in init) write access to create Projects. Two scopes feels right but adds UX complexity ("approve these two scopes" vs "approve full account access"). Worth a UX call: do we go with two-scope precision or one-scope simplicity in v1.

**Account-per-machine vs account-per-shell.** v1 stores the account token in `~/.config/octobercms/auth.yml` (one logged-in account per machine). Some agency developers will want different accounts per client. Open question: do we support `OCTOBER_PROFILE=client-acme` style profile switching in v1, or defer to v2. Leaning defer, but it's a real workflow.

**Paid third-party plugin licensing.** Paid plugins from the OctoberCMS Marketplace use the same Composer auth mechanism against the Update Gateway, so they ride for free on the core licence credential flow. However, plugins distributed outside the OctoberCMS Marketplace (e.g. private Composer repositories, GitHub-hosted private packages) need their own auth tokens. Open question: do we extend the auth handling to support multiple credentials, and how does `init` discover and prompt for them? Likely an `octobercms auth add <hostname>` command in v2, but we need a clear v1 escape hatch for users with one or two private repos.

**Image rebuilding cost.** Build-time plugin installation means every plugin change rebuilds the image. For developers with many plugins or slow build environments, this is friction. Acceptable for v1; may need a runtime overlay model in v2 for some users.

**Existing OctoberCMS sites.** How do existing self-hosters migrate their sites onto the new tooling? Likely a separate `octobercms migrate-existing` command (v2) that introspects an existing install and generates appropriate config and plugin lists. v1 documents the manual migration path.

**Database migrations during rollback.** If a deploy fails after migrations have run, rolling back the code leaves the database ahead of the code. OctoberCMS migrations are mostly additive but not always. Mitigation: encourage `octobercms backup` before risky deploys; document the manual rollback procedure clearly. v2 may introduce a "migration plan review" step before destructive changes.

**Kamal version coupling.** Kamal moves fast and occasionally breaks compat. Our integration test suite needs to run against the supported Kamal version range on every CLI release. Costly but necessary.
