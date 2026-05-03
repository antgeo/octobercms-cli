# OctoberCMS CLI Installer — v1 Plan

## Goal

Ship a Ruby CLI gem and an official Docker image that together let any developer deploy a production OctoberCMS site to a server they own with a single command. Built on Kamal as the deployment engine.

The v1 target is **"`octobercms init` → `octobercms deploy` → working HTTPS site in under 15 minutes"** for a developer who already has a Linux server and a domain.

## Scope

### In scope for v1

- `octobercms` Ruby gem with the core command set
- Single official Docker image (one PHP version; OctoberCMS version is determined by the user's own project)
- Kamal-based deployment with kamal-proxy for TLS
- MySQL via Kamal accessory (single-server) and external managed MySQL support
- Secure local storage of the OctoberCMS licence key; automatic build-time `project:set` via Docker BuildKit secret so `auth.json` is generated inside the build layer and never enters the image
- Composer-based plugin add/remove
- Manual backup/restore for database and storage
- A documentation site with a 10-minute "deploy your first site" tutorial

### Out of scope for v1 (deferred to v2)

- Multiple PHP versions
- Theme management commands
- Scheduled backups and retention policies
- R2/S3 storage driver integration
- Multi-server deploys (Kamal supports it; we just don't optimise the UX)
- Staging environments
- Plugin marketplace integration
- Multi-account profiles (`OCTOBER_PROFILE=client-acme` style switching)
- Auth handling for non-Marketplace private Composer repos beyond manual `auth.json` editing
- Web UI of any kind
- `octobercms upgrade` for OctoberCMS version bumps

### Explicitly not in v1 or v2

- Hosted SaaS control plane (a separate strategic initiative)
- Windows support for the CLI (macOS and Linux only)
- Support for OctoberCMS versions older than the current stable release

## Deliverables

1. **`octobercms` Ruby gem** published to RubyGems
2. **`octobercms/octobercms` Docker image** published to Docker Hub and GHCR
3. **Documentation site** at a subdomain of octobercms.com with install guide, command reference, and the getting-started tutorial
4. **Reference deployment template repo** that `octobercms init` clones from
5. **One end-to-end smoke test** in CI that provisions a Hetzner VPS, runs `octobercms init` and `octobercms deploy`, verifies the site is reachable over HTTPS, then tears down

## Milestones

### M1 — Docker runtime image foundation (weeks 1-3) ✅ COMPLETE

The image is the long-term commitment, so it ships first and gets the most review.

**Model:** Runtime environment only (Laravel Sail-style). No OctoberCMS code is baked in. Users bring their own OctoberCMS project and build a derived image on top of the runtime.

- Single-stage Dockerfile: `php:8.3-fpm-alpine` with PHP extensions, Nginx, and s6-overlay
- No `composer:2` vendor stage — Composer runs in the user's derived image, not in this repo
- s6-overlay v3 for process supervision (PHP-FPM + Nginx in one container)
- Volume contract finalised: `/app/storage` (writable user data) is the only required persistent volume; `/app/plugins` and `/app/themes` are writable by `www-data` for admin UI installer support
- `generate-env` oneshot writes `/app/.env` from environment variables before PHP starts; skips if `.env` already exists
- `/up` health check endpoint — the user's OctoberCMS application is responsible for implementing this route; the CLI scaffolds a healthcheck plugin in M3
- Image published to GHCR with PHP-version tags (`ghcr.io/antgeo/octobercms:php8.3`, `latest`)
- Image size target: under 300 MB compressed (CI enforces)
- README documents how to build a derived image, the env var contract, volume contract, and debugging recipes

**Exit criteria:** A developer can `FROM ghcr.io/antgeo/octobercms:php8.3`, COPY their OctoberCMS project in, `docker run -e ... myapp:latest` against their own MySQL, and get a working OctoberCMS site at `localhost:80`.

### M2 — Licence key management (weeks 4-5)

The credential is the OctoberCMS **licence key** — a single string the user already has from their account. At build time the CLI passes it as a BuildKit secret; the generated `Dockerfile` runs `php artisan project:set <key>` inside the vendor stage, which calls the OctoberCMS API, generates `auth.json`, and makes it available to `composer install`. The key and `auth.json` are never written to any image layer.

- `octobercms auth setup` — prompts for the licence key, validates it by running `php artisan project:set` in a one-shot container against the user's project, and stores it at `~/.config/octobercms/auth.yml` (`0600`)
- `octobercms auth status` — confirms a stored key exists and that `project:set` succeeds with it
- `octobercms auth remove` — deletes the stored key
- `OCTOBER_LICENCE_KEY` env var accepted in CI as an alternative to the stored file
- `services/auth_store.rb` — read/write `~/.config/octobercms/auth.yml`; resolves in priority order: `OCTOBER_LICENCE_KEY` env var → stored file
- All licence key values redacted from logs and error output under all circumstances

**Generated Dockerfile template** (produced by M3 `init`):

```dockerfile
# syntax=docker/dockerfile:1.7
FROM composer:2 AS vendor
WORKDIR /app
COPY . .
RUN --mount=type=secret,id=october_licence \
    php artisan project:set $(cat /run/secrets/october_licence) && \
    composer install --no-dev --no-scripts --prefer-dist --no-autoloader --no-interaction
RUN composer dump-autoload --optimize --no-dev --no-interaction

FROM ghcr.io/antgeo/octobercms:php8.3
COPY --from=vendor /app /app
RUN chown -R www-data:www-data /app
```

**Exit criteria:** A developer can run `octobercms auth setup`, enter their licence key, and have `octobercms auth status` confirm it is valid. A subsequent `octobercms deploy` runs `project:set` inside the build via BuildKit secret with no extra steps from the developer. CI works via `OCTOBER_LICENCE_KEY`.

### M3 — Gem skeleton and `init` command (weeks 6-7)

Builds on M2's credential management. Run inside the user's existing OctoberCMS project directory.

- Thor-based command tree with `tty-prompt` for interactive flows and `tty-spinner` for progress
- `octobercms init` command: detects an existing OctoberCMS project, then prompts for deployment config — domain, server address, database choice, container registry
- If M2 licence key is not yet configured, triggers `auth setup` inline before proceeding
- Generators for `Dockerfile` (uses the M2 template: `project:set` via BuildKit secret → `composer install` → FROM M1 runtime), `config/deploy.yml`, `.kamal/secrets`, `.env.example`, `.gitignore`
- The generated `Dockerfile` handles `project:set` and `composer install` automatically — the developer never writes this boilerplate
- `.gitignore` always excludes `auth.json`, `.env`, and `.kamal/secrets`
- Generators detect existing files and prompt or merge rather than clobber
- All generators use ERB templates that live in the gem; output is deterministic and diffable
- Project structure follows Kamal conventions so `kamal` commands work alongside `octobercms` commands
- Gem published to RubyGems as `0.1.0` (pre-release)

**Exit criteria:** A developer can run `octobercms init` inside their OctoberCMS project, answer the prompts, and end up with a `Dockerfile` targeting the M1 runtime image, a valid `config/deploy.yml`, properly gitignored secrets, and a `doctor` run that passes.

### M4 — Deploy lifecycle (weeks 8-10)

- `octobercms deploy` orchestrates the full pipeline: pre-flight checks → build → push → migrate → rolling deploy → post-deploy
- Pre-flight checks include licence key presence and validity; failures here are fast and clear
- Build step resolves the licence key (via `auth_store.rb`) and runs `docker build DOCKER_BUILDKIT=1 --secret id=october_licence,env=OCTOBER_LICENCE_KEY`; the `project:set` call inside the Dockerfile handles key exchange and `auth.json` generation within the build layer
- Migrations run in a one-shot container before the rolling deploy, not during it
- Each pipeline step is its own subcommand (`octobercms build`, `octobercms migrate`, `octobercms push`) for debugging
- `octobercms doctor` runs pre-flight checks: SSH access, Docker installed on targets (BuildKit-capable), registry reachability, licence key validity (`project:set` round-trip), DNS resolution, ports 80/443 open, env var sanity, gitignore excludes `auth.json` / `.env` / `.kamal/secrets`, git history grep for licence key pattern
- `octobercms console` wraps `kamal app exec --interactive`
- `octobercms logs` wraps `kamal app logs` with sensible defaults (follow, tail 100)
- Kamal is invoked via `tty-command` shell-out, not by `require`-ing it — keeps version coupling loose
- The CLI never logs, echoes, or otherwise surfaces credentials in command output

**Exit criteria:** Running `octobercms deploy` against a fresh Hetzner VPS produces a working HTTPS OctoberCMS site within 5 minutes of the first deploy and within 90 seconds for subsequent deploys, with no licence credentials present in the published image (verified by `docker history` inspection in CI) and no logged tokens or keys in any deploy output (verified by log scanning in CI).

### M5 — Plugin management (weeks 11-12)

- `octobercms plugin add <name>` updates the user's `composer.json`, regenerates `composer.lock`, and prompts to redeploy
- `octobercms plugin remove <name>` reverses the above
- `octobercms plugin list` shows installed plugins with versions and source (Packagist vs local path)
- Local-path plugins supported: a `plugins/` directory in the user's project gets COPYed into their derived image at build
- A small curated index of known-working OctoberCMS plugins (mapping plugin name → Packagist package) ships with the gem; falls back to direct Packagist lookup for anything not in the index
- Admin UI plugin/theme installation is supported at runtime: `/app/plugins` and `/app/themes` are writable by `www-data`; mount them as volumes to persist installs across redeployments

**Exit criteria:** `octobercms plugin add rainlab.user && octobercms deploy` results in the RainLab User plugin being installed and active on the deployed site.

### M6 — Backup and restore (weeks 13-14)

- `octobercms backup` runs `mysqldump` inside the app container, tars `/app/storage`, writes to a configurable destination (local file, S3 URL, R2 URL)
- `octobercms restore <backup-id>` does the inverse, with an interactive confirmation prompt
- Backups are timestamped and include a manifest JSON with OctoberCMS version, plugin versions, and database schema version
- No scheduling in v1 — document how to wire `octobercms backup` into cron or systemd timers manually

**Exit criteria:** A developer can back up a running site, destroy the server, provision a new server, run `octobercms deploy && octobercms restore`, and end up with the original site fully restored.

### M7 — Documentation, tutorial, and launch (weeks 15-16)

- Documentation site live with command reference auto-generated from Thor command definitions
- Getting-started tutorial: "From zero to deployed OctoberCMS in 15 minutes" — tested with three developers who have never used the tool
- Migration guide for existing self-hosters who want to move to the new tooling
- Public announcement: blog post, social posts, forum post on the OctoberCMS community
- Gem version bumped to `1.0.0`

**Exit criteria:** Three external developers complete the tutorial without needing direct support, end-to-end, on three different hosting providers (Hetzner, DigitalOcean, Vultr).

## Engineering principles

**Wrap Kamal, don't fork it.** Shell out via `tty-command`. Pin to a Kamal version range. Bump the range deliberately when tested.

**The gem's interface is independent of Kamal.** Users see `octobercms deploy`, not `kamal deploy`. If we ever need to swap the deployment engine, the user-facing commands don't change.

**Generated config is hand-editable.** Customers will edit `deploy.yml` themselves. Make sure regenerating doesn't clobber their changes — generators detect existing files and either prompt or merge.

**Doctor catches what real users hit.** Every support ticket that turns out to be an environmental issue (SSH key, firewall, DNS) becomes a new check in `doctor`. Treat the doctor command as the support team's first line of defence.

**The Docker image's volume contract is sacred.** Once published, `/app/storage` is the writable volume. Forever. Any change is a major version bump and a documented migration.

## Risks and mitigations

**Licence key compromise.** A leaked key allows an attacker to install OctoberCMS packages on their own builds. Mitigation: file mode `0600` enforced; key never logged or displayed; redaction filter on all output; `octobercms auth remove` deletes the stored key; `doctor` greps git history for any string matching the licence key format.

**`project:set` network dependency at build time.** The `project:set` artisan command calls the OctoberCMS API to exchange the licence key for Composer credentials. If the OctoberCMS API is unreachable (network outage, rate limit), the build fails. Mitigation: `doctor` validates the round-trip before deploy; clear error message distinguishes API unreachable vs invalid key vs rate limited.

**Kamal makes a breaking change mid-development.** Mitigation: pin to a known-good Kamal version, integrate Kamal updates via a dedicated test cycle, abstract Kamal-specific concepts behind our own service objects.

**OctoberCMS plugin ecosystem isn't all on Packagist.** Mitigation: ship a curated index for the top 50 plugins, document how to add local-path plugins, plan for a private Packagist (`satis`) in v2 if it becomes a real friction point.

**Customers want to install plugins via the OctoberCMS admin UI.** Both paths are supported: build-time via Composer (recommended for immutable deploys) and runtime via the admin UI (supported because `/app/plugins` and `/app/themes` are writable by `www-data`). Users who want admin UI installs to survive redeployments mount those directories as volumes.

**Licence key or `auth.json` accidentally committed or baked into images.** Mitigation: `init` always writes `auth.json`, `.env`, and `.kamal/secrets` to `.gitignore`; `project:set` runs inside the BuildKit secret mount so `auth.json` is generated and discarded within a single layer; `doctor` greps git history for licence key patterns and warns loudly.

**Older Docker daemons without BuildKit support.** Mitigation: `doctor` checks Docker version on target servers and on the developer's machine, requires BuildKit-capable Docker (20.10+, which has been default for years), produces a clear upgrade message if the check fails.

**Ruby installation is a barrier for some developers.** Mitigation: document install via Homebrew, `mise`, and `asdf`. Defer self-contained binary distribution to v2 unless friction is severe.

**Single-PHP-version v1 leaves PHP 8.2 users stranded.** Mitigation: explicitly document the supported version, provide a clear timeline for additional versions in v2, accept that some users will wait.

**Docker image bloat.** Mitigation: 300 MB compressed target enforced in CI; image size regression breaks the build.

## Team and time

Realistic estimate: **16 weeks for one experienced engineer working full-time on the CLI**, plus coordination time from the OctoberCMS web team for the account API endpoints (M2 dependency). Roughly 7 months part-time alongside other commitments. The Docker image (M1), the auth and API integration (M2), and the deploy lifecycle (M4) are the milestones most likely to slip — all involve real-world infrastructure debugging that doesn't compress well.

The web team's API work is on the critical path. If it slips by more than 2 weeks, the contingency plan is to ship v1 with a manual-credential fallback flow (the original design before API integration was promoted to v1) and add the API integration as a v1.1 update once the API is ready. This contingency should be agreed in writing in week 1 so the decision is fast if it becomes necessary.

## Dependencies on other teams

This is an independent third-party tool. There are no external team dependencies on the critical path. M2 depends only on the publicly documented OctoberCMS gateway (`gateway.octobercms.com`) continuing to accept HTTP Basic credentials for Composer auth, which is stable behaviour tied to the existing licensing model.

## Success metrics for v1

- 50+ GitHub stars on the CLI repo within 60 days of launch
- 100+ docker pulls per week of the official image within 90 days
- 10+ external contributors filing bug reports or PRs (a signal that real people are using it)
- Tutorial completion time under 15 minutes for at least 8 of the next 10 first-time users we observe
- Zero data-loss incidents in the backup/restore path during the first 90 days
