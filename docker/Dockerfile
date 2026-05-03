# syntax=docker/dockerfile:1.7

# ── Stage 1: Composer vendor ──────────────────────────────────────────────────
# Requires OctoberCMS gateway credentials.
# Build the production image with:
#   DOCKER_BUILDKIT=1 docker build \
#     --secret id=composer_auth,src=~/.composer/auth.json \
#     -f docker/Dockerfile -t octobercms:latest .
FROM composer:2 AS vendor

WORKDIR /app

COPY composer.json ./

# The bind mount on /build-ctx lets us use composer.lock when it exists
# (reproducible builds) while succeeding on the initial bootstrap run when it
# has not yet been generated. After the first successful build, extract the
# generated lock file and commit it so all subsequent builds are pinned.
RUN --mount=type=bind,source=.,target=/build-ctx \
    --mount=type=secret,id=composer_auth,target=/app/auth.json,required=false \
    [ -f /build-ctx/composer.lock ] && cp /build-ctx/composer.lock . || true \
 && composer install \
      --no-dev \
      --no-scripts \
      --prefer-dist \
      --no-autoloader \
      --no-interaction \
      --ansi

COPY . .

RUN composer dump-autoload --optimize --no-dev --no-interaction

# ── Stage 2: Infrastructure base ─────────────────────────────────────────────
# PHP + Nginx + s6-overlay + all config. No OctoberCMS application code.
# Can be built without credentials — useful for development and infrastructure
# testing (generate-env.sh, nginx routing, image structure).
#
# Build: docker build --target base -f docker/Dockerfile -t octobercms:base .
FROM php:8.3-fpm-alpine AS base

ARG S6_OVERLAY_VERSION=3.2.2.0
ARG TARGETARCH

# ── System packages + PHP extensions ─────────────────────────────────────────
# .build-deps is a virtual group deleted in the same layer as the compile step
# so the ~20 MB of -dev headers never make it into the final image.
RUN apk add --no-cache \
        nginx \
        curl \
        mysql-client \
        xz \
        freetype \
        libjpeg-turbo \
        libpng \
        libwebp \
        libzip \
 && apk add --no-cache --virtual .build-deps \
        freetype-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libzip-dev \
        oniguruma-dev \
 && docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
        --with-webp \
 && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql \
        gd \
        opcache \
        bcmath \
        mbstring \
        zip \
 && docker-php-ext-enable opcache \
 && apk del .build-deps \
 && rm -rf /var/cache/apk/*

# ── s6-overlay v3 ────────────────────────────────────────────────────────────
# Four tarballs are required: noarch scripts, arch-specific binaries, and the
# two symlinks tarballs introduced in 3.1. Omitting the symlinks tarballs breaks
# the /command/ path and service run scripts fail silently.
RUN set -ex \
 && case "${TARGETARCH}" in \
      amd64) S6_ARCH=x86_64  ;; \
      arm64) S6_ARCH=aarch64 ;; \
      arm*)  S6_ARCH=armhf   ;; \
      *) echo "unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac \
 && BASE="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}" \
 && curl -fsSL "${BASE}/s6-overlay-noarch.tar.xz"          | tar -C / -Jxp \
 && curl -fsSL "${BASE}/s6-overlay-${S6_ARCH}.tar.xz"      | tar -C / -Jxp \
 && curl -fsSL "${BASE}/s6-overlay-symlinks-noarch.tar.xz"  | tar -C / -Jxp \
 && curl -fsSL "${BASE}/s6-overlay-symlinks-arch.tar.xz"    | tar -C / -Jxp

# ── rootfs overlay ────────────────────────────────────────────────────────────
COPY docker/rootfs/ /

# ── Permissions + storage directories ────────────────────────────────────────
RUN find /etc/s6-overlay/s6-rc.d -name run -o -name up | xargs chmod +x \
 && chmod +x /etc/s6-overlay/scripts/generate-env.sh \
 && mkdir -p \
        /app/storage/app \
        /app/storage/framework/cache \
        /app/storage/framework/sessions \
        /app/storage/framework/views \
        /app/storage/logs \
        /app/plugins \
        /app/themes \
        /app-skeleton/plugins \
        /app-skeleton/themes \
 && chown -R www-data:www-data /app/storage /app/plugins /app/themes /app-skeleton \
 && chown -R www-data:www-data /var/lib/nginx /var/log/nginx

WORKDIR /app

EXPOSE 80

# /init must be PID 1 — s6-overlay v3 refuses to start otherwise.
ENTRYPOINT ["/init"]

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD curl -f http://localhost/up || exit 1

# ── Stage 3: Production image ─────────────────────────────────────────────────
# Adds OctoberCMS application code from the vendor stage.
# This is the default build target.
FROM base

COPY --from=vendor /app /app

# Move plugins and themes to a skeleton directory so the init script can seed
# the volume-mounted directories on first run. This allows plugins and themes
# installed via the OctoberCMS admin UI to persist across deployments.
RUN mv /app/plugins /app-skeleton/plugins \
 && (mv /app/themes /app-skeleton/themes 2>/dev/null || mkdir -p /app-skeleton/themes) \
 && mkdir -p /app/plugins /app/themes \
 && chown -R www-data:www-data \
        /app/storage \
        /app/plugins \
        /app/themes \
        /app-skeleton
