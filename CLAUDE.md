# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This repository is in the **design phase** — only `design.md` and `plan.md` exist. No implementation code has been written yet. The architecture is fully specified in those two documents; implementation starts at M1 (Docker image).

## What this project is

**Third-party project — not affiliated with or endorsed by the OctoberCMS team.**

A Ruby gem (`octobercms`) and Docker image that make deploying OctoberCMS a single-command operation. The gem wraps **Kamal** as the deployment engine and adds OctoberCMS-aware scaffolding, lifecycle commands, and account API integration.

Three artifacts together form the product:
1. **`octobercms/octobercms` Docker image** — PHP-FPM + Nginx (s6-overlay), multi-stage build with BuildKit secret mount for Composer auth
2. **`octobercms` Ruby gem** — Thor-based CLI, TTY toolkit for UX, shells out to Kamal via `tty-command`
3. **Deploy template** — what `octobercms init` generates into the customer's project directory (ERB templates rendered at init time)

## Planned gem structure

```
bin/octobercms               # CLI entrypoint
lib/octobercms/
  cli.rb                     # Thor command tree root
  version.rb
  config.rb                  # Project config loader
  commands/                  # Thin: parse, prompt, dispatch
    init.rb
    deploy.rb
    plugin.rb
    backup.rb / restore.rb
    console.rb / logs.rb
    doctor.rb
    auth/{login,logout,status,refresh}.rb
    project/{list,select,create}.rb
  generators/                # ERB template renderers
    dockerfile.rb / deploy_yml.rb / env.rb
    composer_json.rb / auth_json.rb
    gitignore.rb / project_file.rb
  services/                  # Business logic
    kamal.rb                 # tty-command wrapper around kamal
    composer.rb
    docker.rb                # BuildKit secret handling
    backup_engine.rb
    plugin_index.rb          # curated plugin → Packagist mapping
    api_client.rb            # OctoberCMS account API
    auth_store.rb            # ~/.config/octobercms/auth.yml
    oauth_listener.rb        # local HTTP listener for OAuth callback
    license.rb               # resolution, validation, redaction
  templates/                 # ERB templates (Dockerfile, deploy.yml, etc.)
test/
```

Commands are thin (parsing, prompting, dispatching). Logic lives in services and generators.

## Build, test, and lint commands

*(Not yet configured — add these to this file when the Gemfile, Rakefile, and .gemspec are created.)*

Expected setup:
- **Test:** `bundle exec rake test` (or `bundle exec rspec` if RSpec is chosen)
- **Lint:** `bundle exec rubocop`
- **Gem build:** `gem build octobercms.gemspec`
- **Single test:** `bundle exec ruby -Itest test/path/to/test_file.rb` (minitest) or `bundle exec rspec spec/path/to/spec.rb`

Ruby requirement: **3.2+** (support two latest stable versions).

## Key dependencies

- **Thor** — command tree (same as Rails CLI and Kamal)
- **tty-prompt, tty-spinner, tty-command, tty-logger** — interactive UX and shell-out
- **dotenv** — `.env` parsing
- **faraday** or **http.rb** — HTTP client for API calls and Packagist lookups

Deliberately avoided: ActiveRecord/Sequel, Sidekiq/Resque, bundler runtime bloat.

## Architecture: how deploy works

`octobercms deploy` pipeline:

1. **Pre-flight** — auth state, licence health, composer.lock validity
2. **Build** — fetches licence key from OctoberCMS API → writes temp `auth.json` → `docker build DOCKER_BUILDKIT=1 --secret id=composer_auth,src=<temp>` → deletes temp file in `begin/ensure`
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

## The Docker image contract

Two writable surfaces (this is public API — changes require a major version bump):
- `/app/storage` — the only persistent volume (uploads, cache, sessions, logs)
- `/app/plugins` and `/app/themes` — baked at build time; volume mount is an escape hatch only

Runtime config via environment variables (rendered from ERB templates at container start). Key vars: `APP_KEY`, `APP_URL`, `DB_*`. Licence credentials are **not** runtime env vars.

Health check endpoint: `/up` — returns 200 only when PHP-FPM is responsive, DB is reachable, and the migrations table exists.

Image tags: `octobercms:<cms-version>-php<php-version>`, `octobercms:<cms-version>`, `octobercms:latest`. Size target: <300 MB compressed.

## Engineering principles

- **Wrap Kamal, don't fork it.** Shell out via `tty-command`. The user sees `octobercms deploy`, not `kamal deploy`.
- **Generated config is hand-editable.** Generators detect existing files and prompt or merge rather than clobber.
- **Doctor catches support tickets.** Every environmental issue that turns into a support ticket becomes a new `doctor` check. Doctor is the support team's first line of defence.
- **The volume contract is sacred.** `/app/storage` is the writable volume forever.
- **Secrets never enter image layers.** BuildKit secret mounts only. CI verifies via `docker history` inspection.
- **Migrations run before rolling deploy**, not during it, to avoid race conditions.

## Plugin management

- Build-time via Composer is the primary path; runtime volume mount is the escape hatch
- Plugin index YAML ships with the gem: maps friendly names (`rainlab.user`) to Packagist packages (`rainlab/user`)
- `plugins/` directory in the project is COPYed into the image at build for local-path plugins
