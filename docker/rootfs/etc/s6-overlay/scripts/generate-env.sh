#!/usr/bin/with-contenv sh
# with-contenv makes Docker-injected environment variables available in this
# script. Without it, variables passed via --env or --env-file are not visible.
set -eu

ENV_FILE="/app/.env"

# If .env already exists (operator bind-mounted one, or a derived image baked
# it), leave it alone — the operator knows what they're doing.
if [ -f "${ENV_FILE}" ]; then
    echo "[generate-env] .env already present, skipping generation"
    exit 0
fi

# Fail fast with a clear message rather than letting PHP die cryptically.
required_vars="APP_KEY APP_URL DB_CONNECTION DB_HOST DB_DATABASE DB_USERNAME DB_PASSWORD"
for var in $required_vars; do
    eval "val=\${${var}:-}"
    if [ -z "$val" ]; then
        echo "[generate-env] ERROR: required environment variable ${var} is not set" >&2
        exit 1
    fi
done

# STORAGE_DRIVER is the public env var contract; Laravel expects FILESYSTEM_DISK.
# The mapping lives here, not exposed to the operator.
FILESYSTEM_DISK="${STORAGE_DRIVER:-local}"

cat > "${ENV_FILE}" << DOTENV
APP_NAME=${APP_NAME:-OctoberCMS}
APP_ENV=${APP_ENV:-production}
APP_KEY=${APP_KEY}
APP_DEBUG=${APP_DEBUG:-false}
APP_URL=${APP_URL}
APP_LOCALE=${APP_LOCALE:-en}

LOG_CHANNEL=${LOG_CHANNEL:-stderr}
LOG_LEVEL=${LOG_LEVEL:-error}

DB_CONNECTION=${DB_CONNECTION}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT:-3306}
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}

CACHE_DRIVER=${CACHE_DRIVER:-file}
SESSION_DRIVER=${SESSION_DRIVER:-file}
QUEUE_CONNECTION=${QUEUE_CONNECTION:-sync}

FILESYSTEM_DISK=${FILESYSTEM_DISK}

MAIL_MAILER=${MAIL_MAILER:-log}
MAIL_FROM_ADDRESS=${MAIL_FROM_ADDRESS:-hello@example.com}
MAIL_FROM_NAME="${MAIL_FROM_NAME:-OctoberCMS}"
DOTENV

chmod 640 "${ENV_FILE}"
chown www-data:www-data "${ENV_FILE}"

echo "[generate-env] .env written"

# Seed plugins and themes from the image skeleton on first run.
# When a volume is mounted at /app/plugins or /app/themes the directory starts
# empty. Copying from /app-skeleton/ restores the baked-in defaults so the CMS
# works out of the box. Subsequent runs leave existing content untouched,
# preserving anything installed via the admin UI.
for dir in plugins themes; do
    if [ -d "/app-skeleton/${dir}" ] && [ -z "$(ls -A /app/${dir} 2>/dev/null)" ]; then
        cp -r "/app-skeleton/${dir}/." "/app/${dir}/"
        chown -R www-data:www-data "/app/${dir}"
        echo "[generate-env] seeded /app/${dir} from skeleton"
    fi
done
