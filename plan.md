# OctoberCMS CLI Installer — v1 Plan

## Goal

Ship a Ruby CLI gem and an official Docker image that together let any developer deploy a production OctoberCMS site to a server they own with a single command. Built on Kamal as the deployment engine.

The v1 target is **"`octobercms init` → `octobercms deploy` → working HTTPS site in under 15 minutes"** for a developer who already has a Linux server and a domain.

## Scope

### In scope for v1

- `octobercms` Ruby gem with the core command set
- Single official Docker image (one PHP version, one OctoberCMS version)
- Kamal-based deployment with kamal-proxy for TLS
- MySQL via Kamal accessory (single-server) and external managed MySQL support
- OctoberCMS account integration via API: browser-based OAuth login, Project picker, automatic licence key fetching at build time
- Build-time Composer auth via Docker BuildKit secrets (licence credentials never enter image layers)
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

### M1 — Docker image foundation (weeks 1-3)

The image is the long-term commitment, so it ships first and gets the most review.

- Multi-stage Dockerfile: `composer:2` for vendor stage, `php:8.3-fpm-alpine` for runtime
- s6-overlay for process supervision (PHP-FPM + Nginx in one container)
- Volume contract finalised: `/app/storage` (writable user data) is the only persistent volume; plugins and themes are baked at build time
- Entrypoint script renders `config/*.php` from environment variables on startup
- `/up` health check endpoint returns 200 only when PHP-FPM is responsive and the database is reachable
- Image published to GHCR with semver tags (`octobercms:3.5`, `octobercms:3.5-php8.3`, `octobercms:latest`)
- Image size target: under 300 MB compressed
- README documents the env var contract, volume contract, and exec-into-container debugging recipes

**Exit criteria:** A developer can `docker run -e ... octobercms/octobercms:latest` against their own MySQL and get a working OctoberCMS site at `localhost:80`.

### M2 — Account auth and API client (weeks 4-5)

Coordinated with the OctoberCMS web team to define and ship the account API surface that the CLI depends on. This milestone is partially blocked on the API being ready; in parallel the CLI team builds against a mocked API.

API surface required (delivered by the OctoberCMS web team):
- OAuth-style authorize endpoint with local callback (`/cli/authorize`)
- Token introspection endpoint
- List Projects endpoint (paginated)
- Fetch licence key for a Project ID endpoint
- Create Project endpoint (with free-licence default for new accounts)
- Token revocation endpoint
- Machine-account token generation (in the account portal UI)

CLI work:
- `octobercms auth login` browser-based flow with local HTTP listener on a random port
- `octobercms auth login --token <token>` fallback for non-interactive environments
- `octobercms auth logout`, `auth status`, `auth refresh` commands
- `octobercms project list`, `project select`, `project create` commands
- `~/.config/octobercms/auth.yml` storage with `0600` permissions
- `OCTOBER_API_TOKEN` env var support for CI
- `services/api_client.rb` with retries, rate-limit handling, and error mapping
- `services/oauth_listener.rb` that handles the local callback securely (CSRF state, port collisions, browser timeout)
- All credentials redacted from logs and error output

**Exit criteria:** A customer can run `octobercms auth login`, complete the browser flow, then run `octobercms project list` and see their actual Projects from their account. `octobercms auth status` shows licence type and expiry for each Project.

### M3 — Gem skeleton and `init` command (weeks 6-7)

Builds on M2's auth and API client.

- Thor-based command tree with `tty-prompt` for interactive flows and `tty-spinner` for progress
- `octobercms init` command with the full interactive flow: project name, domain, server, database choice, registry choice, **Project picker (using the M2 API client)**
- The init flow handles unauthenticated users by triggering `auth login` inline before proceeding
- The Project picker shows licence type and expiry inline, with a "Create new Project (free first-year licence)" inline option that calls the API to provision a Project
- Generators for `Dockerfile`, `config/deploy.yml`, `.kamal/project` (committable, contains Project ID), `.kamal/secrets`, `.env.example`, `composer.json`, `auth.json.example`, `.gitignore`
- `.gitignore` always includes `auth.json`, `.env`, and `.kamal/secrets`
- All generators use ERB templates that live in the gem; output is deterministic and diffable
- Project structure follows Kamal conventions so `kamal` commands work alongside `octobercms` commands
- Gem published to RubyGems as `0.1.0` (pre-release)

**Exit criteria:** A developer can run `octobercms init my-site`, log in via browser if needed, pick a Project from their account, answer the remaining prompts, and end up with a directory containing valid Kamal config, a committable `.kamal/project`, properly gitignored secrets, and a Dockerfile that targets the M1 Docker image with BuildKit secret mounts.

### M4 — Deploy lifecycle (weeks 8-10)

- `octobercms deploy` orchestrates the full pipeline: pre-flight checks → fetch licence key → build → push → migrate → rolling deploy → post-deploy
- Pre-flight checks include licence health (via the API) and authentication state; failures here are fast and clear
- Build step fetches the licence key from the API, generates a temporary `auth.json` in a secure temp directory, and uses Docker BuildKit (`DOCKER_BUILDKIT=1`) with `--mount=type=secret,id=composer_auth` to inject it into the build without baking it into any image layer; the temp file is deleted in a `begin/ensure` block
- Migrations run in a one-shot container before the rolling deploy, not during it
- Each pipeline step is its own subcommand (`octobercms build`, `octobercms migrate`, `octobercms push`) for debugging
- `octobercms doctor` runs pre-flight checks: SSH access, Docker installed on targets (with BuildKit support), registry reachability, **account auth validity, Project licence health (warns at 30 days to expiry, errors at expired), Update Gateway round-trip**, DNS resolution, ports 80/443 open, env var sanity, gitignore correctly excludes `auth.json` / `.env` / `.kamal/secrets`, git history grep for licence key patterns
- `octobercms console` wraps `kamal app exec --interactive`
- `octobercms logs` wraps `kamal app logs` with sensible defaults (follow, tail 100)
- Kamal is invoked via `tty-command` shell-out, not by `require`-ing it — keeps version coupling loose
- The CLI never logs, echoes, or otherwise surfaces the licence key or account token in command output

**Exit criteria:** Running `octobercms deploy` against a fresh Hetzner VPS produces a working HTTPS OctoberCMS site within 5 minutes of the first deploy and within 90 seconds for subsequent deploys, with no licence credentials present in the published image (verified by `docker history` inspection in CI) and no logged tokens or keys in any deploy output (verified by log scanning in CI).

### M5 — Plugin management (weeks 11-12)

- `octobercms plugin add <name>` updates `composer.json`, regenerates `composer.lock`, and prompts to redeploy
- `octobercms plugin remove <name>` reverses the above
- `octobercms plugin list` shows installed plugins with versions and source (Packagist vs local path)
- Local-path plugins supported: a `plugins/` directory in the project gets COPYed into the image at build
- A small curated index of known-working OctoberCMS plugins (mapping plugin name → Packagist package) ships with the gem; falls back to direct Packagist lookup for anything not in the index

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

**OctoberCMS account API not ready in time for M2.** The CLI's M2 depends on the OctoberCMS web team shipping the account API endpoints. If those slip, M2 slips and everything downstream slips with it. Mitigation: API spec is locked in week 1 in a joint design doc; the CLI team builds against a mocked API in parallel; weekly sync between CLI and web teams; agreed contingency to ship the v1 with a manual-credential fallback flow if the API is more than 2 weeks late.

**OAuth flow edge cases.** Browser-based auth has many failure modes: port already in use, browser doesn't open, customer closes browser before completing, CSRF state mismatch, network timeouts. Mitigation: model the implementation directly on `gh auth login` and `flyctl auth login` (both well-tested patterns); ship a `--token` fallback for any flow that breaks; comprehensive test matrix in CI covering the common failure modes.

**Account token compromise.** A leaked token grants read access to the customer's Project list and licence keys. Mitigation: file mode `0600` enforced; token never logged or displayed; redaction filter on all output; `octobercms auth refresh` and `auth logout` for rotation/revocation; clear documentation on token security; the OctoberCMS account portal must support revoking individual tokens (web team dependency).

**Kamal makes a breaking change mid-development.** Mitigation: pin to a known-good Kamal version, integrate Kamal updates via a dedicated test cycle, abstract Kamal-specific concepts behind our own service objects.

**OctoberCMS plugin ecosystem isn't all on Packagist.** Mitigation: ship a curated index for the top 50 plugins, document how to add local-path plugins, plan for a private Packagist (`satis`) in v2 if it becomes a real friction point.

**Customers want to install plugins via the OctoberCMS admin UI.** Mitigation: document the build-time model clearly, position it as a feature (immutable deploys, atomic rollbacks), provide a `plugins/` directory escape hatch for local development.

**Customers don't realise they need a Project License until first deploy fails.** Mitigation: with the API integration the CLI knows the customer's licence state from `auth login` onwards — `init` shows licence health inline in the Project picker, `doctor` warns on every run when licence is approaching expiry, deploys fail fast in pre-flight rather than 30 seconds into a Docker build. The "Create new Project (free first-year licence)" inline option converts evaluators directly without requiring them to leave the CLI.

**Licence credentials accidentally committed or baked into images.** Mitigation: with the API integration, licence keys never live in the project directory at all — they're fetched per-build. `init` always writes `auth.json`, `.env`, and `.kamal/secrets` to `.gitignore`; the build uses BuildKit secret mounts so credentials never enter image layers; CI runs `docker history` against the built image to assert no auth values are present; `doctor` greps git history for any string matching the licence key format and warns loudly.

**Older Docker daemons without BuildKit support.** Mitigation: `doctor` checks Docker version on target servers and on the developer's machine, requires BuildKit-capable Docker (20.10+, which has been default for years), produces a clear upgrade message if the check fails.

**Ruby installation is a barrier for some developers.** Mitigation: document install via Homebrew, `mise`, and `asdf`. Defer self-contained binary distribution to v2 unless friction is severe.

**Single-PHP-version v1 leaves PHP 8.2 users stranded.** Mitigation: explicitly document the supported version, provide a clear timeline for additional versions in v2, accept that some users will wait.

**Docker image bloat.** Mitigation: 300 MB compressed target enforced in CI; image size regression breaks the build.

## Team and time

Realistic estimate: **16 weeks for one experienced engineer working full-time on the CLI**, plus coordination time from the OctoberCMS web team for the account API endpoints (M2 dependency). Roughly 7 months part-time alongside other commitments. The Docker image (M1), the auth and API integration (M2), and the deploy lifecycle (M4) are the milestones most likely to slip — all involve real-world infrastructure debugging that doesn't compress well.

The web team's API work is on the critical path. If it slips by more than 2 weeks, the contingency plan is to ship v1 with a manual-credential fallback flow (the original design before API integration was promoted to v1) and add the API integration as a v1.1 update once the API is ready. This contingency should be agreed in writing in week 1 so the decision is fast if it becomes necessary.

## Dependencies on other teams

**OctoberCMS web team (M2 critical path):** ship the account API endpoints (authorize, token introspect, list projects, fetch licence key, create project, revoke token), plus machine-account token generation in the account portal UI. Estimated 2-3 weeks of web-team effort, ideally completed by week 4 of the CLI plan so M2 has a real API to integrate against rather than a mock for its full duration.

**OctoberCMS support team:** review the doctor command's error messages and the docs site's troubleshooting section before launch. Estimated 1 week of part-time review across M6 and M7.

## Success metrics for v1

- 50+ GitHub stars on the CLI repo within 60 days of launch
- 100+ docker pulls per week of the official image within 90 days
- 10+ external contributors filing bug reports or PRs (a signal that real people are using it)
- Tutorial completion time under 15 minutes for at least 8 of the next 10 first-time users we observe
- Zero data-loss incidents in the backup/restore path during the first 90 days
