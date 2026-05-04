# OctoberCMS CLI

> **This is an independent, third-party project.** It is not affiliated with, endorsed by, or maintained by the OctoberCMS team. OctoberCMS is a trademark of its respective owners.

A Ruby gem and Docker image that make deploying OctoberCMS a single-command operation against any Linux server. Built on [Kamal](https://kamal-deploy.org) as the deployment engine.

> **Status:** M1 complete ✓ — M2 complete ✓ (`auth` command set, licence key management) — M3 complete ✓ (`init` command, deployment scaffolding) — M4 complete ✓ (`deploy` pipeline, `doctor` checks) — M5 next (backup and restore).

---

## CLI

The `octobercms` gem wraps [Kamal](https://kamal-deploy.org) as the deployment engine and adds OctoberCMS-aware scaffolding and lifecycle commands. Ruby 3.2+ required.

```sh
gem install octobercms   # v0.1.0 — see below for building from source
```

### Building from source

```sh
git clone https://github.com/antgeo/octobercms-cli
cd octobercms-cli
bundle install
bundle exec ruby bin/octobercms help
```

---

## Licence key management

OctoberCMS requires a licence key from your [account](https://octobercms.com/account) for Composer package access. The CLI stores it securely and injects it at build time and runtime automatically.

### Store your licence key

```sh
octobercms auth setup
```

Prompts for your licence key (input is masked), validates it against the OctoberCMS gateway, then stores it:
- **Globally** — `~/.config/octobercms/auth.yml` (mode `0600`), used as the default for all projects
- **Per-project** — `OCTOBER_LICENCE_KEY="<key>"` in `.kamal/secrets` (mode `0600`), used when the current directory has a `.kamal/` folder

The per-project option is offered automatically when you run `setup` inside a project directory.

### Check the active key

```sh
octobercms auth status            # show which source is active
octobercms auth status --validate # also round-trip validate with the gateway
```

Resolution order (highest priority first):

1. `OCTOBER_LICENCE_KEY` environment variable — for CI and operator overrides
2. `OCTOBER_LICENCE_KEY` in `.kamal/secrets` — per-project key
3. `~/.config/octobercms/auth.yml` — global default

### Remove the stored key

```sh
octobercms auth remove           # removes the active source
octobercms auth remove --global  # always removes the global key
```

### CI usage

Set `OCTOBER_LICENCE_KEY` as a repository secret. The CLI reads it automatically — no `auth setup` step needed in CI.

---

## Scaffold your deployment

Inside your OctoberCMS project directory (must contain `composer.json` and `artisan`):

```sh
octobercms init
```

Walks you through your deployment configuration, then generates:

| File | Description |
|------|-------------|
| `Dockerfile` | Multi-stage build; injects your licence key via BuildKit secret |
| `config/deploy.yml` | Kamal config: servers, registry, proxy (TLS), volumes, database |
| `.kamal/secrets` | Secret env var values — mode `0600`, gitignored |
| `.env.example` | Runtime env var reference — safe to commit |
| `.gitignore` | Adds `auth.json`, `.env`, `.kamal/secrets` |
| `.dockerignore` | Adds `.git`, `vendor`, `.env`, `.kamal/secrets` |

On re-run, existing files prompt for overwrite confirmation. Pass `--skip-existing` to skip them silently.

```sh
octobercms init --skip-existing
```

---

## Deploy

Inside your OctoberCMS project directory (must have been set up with `octobercms init`):

```sh
octobercms deploy                  # full pipeline: pre-flight → build → migrate → deploy
octobercms deploy --skip-migrate   # skip the migration step
```

The pipeline in order:

1. Pre-flight checks (local files only — fast)
2. `kamal build push` — builds the image and pushes to your registry
3. `kamal app exec --reuse 'php artisan october:migrate'` — runs migrations before rolling restart
4. `kamal deploy` — rolling restart with health check via `/up`

### Individual steps

```sh
octobercms build    # build and push the image only
octobercms migrate  # run migrations only (in the running container)
```

### Pre-deploy checks

```sh
octobercms doctor            # run all checks: files, Docker, Kamal config, git history
octobercms doctor --validate # also validate the licence key against the OctoberCMS gateway
```

Checks performed:

| # | Check |
|---|-------|
| 1 | `config/deploy.yml` exists |
| 2 | `.kamal/secrets` has all required keys set |
| 3 | Licence key configured |
| 4 | `.gitignore` excludes `auth.json`, `.env`, `.kamal/secrets` |
| 5 | Docker is running |
| 6 | Kamal configuration is valid |
| 7 | Licence key not present in git history |
| 8 | Licence key valid (gateway) — `--validate` only |

### Debugging

```sh
octobercms console             # interactive shell in the running container
octobercms logs                # tail logs (follow, 100 lines)
octobercms logs --lines 50     # tail with custom line count
octobercms logs --no-follow    # print and exit
```

---

## Docker runtime image

The published image (`ghcr.io/antgeo/octobercms:php8.3`) is a runtime environment only — PHP 8.3-FPM + Nginx + s6-overlay, no OctoberCMS code. `octobercms init` generates a `Dockerfile` into your project that builds a derived image on top of it.

See [docker/README.md](docker/README.md) for the full reference: image tags, environment variables, volume contract, process model, health check, and debugging.
