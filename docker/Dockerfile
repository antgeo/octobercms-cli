# syntax=docker/dockerfile:1.7

# OctoberCMS runtime image — PHP-FPM + Nginx + s6-overlay.
#
# This image is a runtime environment. It contains no OctoberCMS application
# code. Users build a derived image on top of this one that COPYs their own
# vendor/, plugins/, themes/, and application scaffold into /app.
#
# Build:
#   docker build -f docker/Dockerfile --build-arg PHP_VERSION=8.4 -t octobercms:php8.4 .
#
# Run (derived image):
#   docker run -e APP_KEY=... -e APP_URL=... -e DB_HOST=... myapp:latest

ARG PHP_VERSION=8.3
FROM php:${PHP_VERSION}-fpm-alpine

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
 && docker-php-ext-install \
        pdo_mysql \
        gd \
        bcmath \
        mbstring \
        zip \
 && (php -r "exit(version_compare(PHP_VERSION,'8.5.0','>=') ? 0 : 1);" || docker-php-ext-enable opcache) \
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

# ── Permissions + writable directories ───────────────────────────────────────
RUN find /etc/s6-overlay/s6-rc.d -name run -o -name up | xargs chmod +x \
 && chmod +x /etc/s6-overlay/scripts/generate-env.sh \
 && chmod 600 /etc/crontabs/www-data \
 && mkdir -p \
        /app/storage/app \
        /app/storage/framework/cache \
        /app/storage/framework/sessions \
        /app/storage/framework/views \
        /app/storage/logs \
        /app/plugins \
        /app/themes \
 && chown -R www-data:www-data /app \
 && chown -R www-data:www-data /var/lib/nginx /var/log/nginx

WORKDIR /app

EXPOSE 80

# /init must be PID 1 — s6-overlay v3 refuses to start otherwise.
ENTRYPOINT ["/init"]

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD curl -f http://localhost/up || exit 1
