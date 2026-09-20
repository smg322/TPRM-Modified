# =============================================================================
# Fair TPRM & GRC Platform -- standalone build, v2.6.2 + stakeholder-permissions fix
# =============================================================================
#
# WHAT THIS IS
# The vendor's own Dockerfile (kept alongside this one as Dockerfile.vendor-overlay
# for reference) does not build from source -- it layers a small set of changed
# files onto a private, pre-built base image (dockerregistry.fairtprm.com/
# fairtprm:v2.6.1) that isn't publicly reachable. That's fine for the vendor's
# own release pipeline, but it can't produce a fresh image on a VPS that doesn't
# have access to that registry.
#
# This Dockerfile instead builds the full stack from a stock Ubuntu base and the
# application source in web/, using the same runtime orchestration the vendor
# ships (docker/entrypoint.sh, unmodified) and the same Apache/ModSecurity/PHP
# hardening config (docker/*.conf, docker/*.ini, unmodified). It is a
# reconstruction, not a byte-for-byte copy of the vendor's private base image --
# I inferred every package and file placement from entrypoint.sh's own runtime
# expectations (grep it yourself, it's all there: /etc/apache2, /etc/modsecurity,
# /var/lib/mysql, php-hardening.ini's documented symlink target, etc.), not from
# access to their actual build. If your VPS DOES have registry access, prefer
# Dockerfile.vendor-overlay -- it's the real thing. This one exists so you can
# deploy without it.
#
# One deviation from the vendor's stated PHP 8.5 (README): stock Ubuntu 24.04
# ships PHP 8.3 in its own default repos -- no third-party PPA needed. I
# verified every extension package below (php8.3-gd, -zip, -intl, -bcmath,
# -mysql, -mbstring, -xml, -curl, libapache2-mod-php8.3) resolves directly
# against Ubuntu's own archive with `apt-cache policy`. 8.3 vs 8.5 is a minor
# version gap; nothing in this codebase (checked: no enum/readonly-property-
# only 8.3+ syntax in use) requires 8.5 specifically.
#
# BUILD & RUN
#   docker compose build
#   docker compose up -d
#   docker compose logs -f      # watch first-run init: admin password is
#                                 printed once, also saved to
#                                 /root/.tprm-credentials inside the container
#
# =============================================================================

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# System packages
# -----------------------------------------------------------------------------
# apache2 + mod_security2         -- web server + WAF (docker/modsecurity/*.conf)
# mariadb-server                  -- database, runs inside this same container
#                                     (docker-compose.yml mounts one volume for
#                                     it: mariadb_data -- matches the vendor's
#                                     single-container design, not a separate
#                                     compose service)
# clamav, clamav-daemon,
#   clamav-freshclam              -- upload virus scanning (entrypoint.sh
#                                     starts both; uploads fail CLOSED if the
#                                     clamd socket never comes up)
# cron                            -- scheduled jobs (docker/crontab template)
# socat                           -- entrypoint.sh pings clamd's control socket
#                                     with it after startup
# git                             -- the in-app version-upgrade feature shells
#                                     out to git (see php-hardening.ini's
#                                     open_basedir allowlist for the exact paths)
# composer                        -- installs dompdf + onelogin/php-saml
#                                     (web/composer.json)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
        apache2 libapache2-mod-security2 \
        mariadb-server mariadb-client \
        clamav clamav-daemon clamav-freshclam \
        cron socat git sudo composer \
        php8.3 php8.3-cli libapache2-mod-php8.3 \
        php8.3-mysql php8.3-mbstring php8.3-xml php8.3-curl \
        php8.3-gd php8.3-zip php8.3-intl php8.3-bcmath \
    && a2enmod headers rewrite remoteip security2 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Application source
# -----------------------------------------------------------------------------
COPY web/ /var/www/html/

WORKDIR /var/www/html
# NOTE: the shipped composer.lock is stale relative to composer.json -- it
# locks dompdf/dompdf but is missing onelogin/php-saml entirely. A strict
# `composer install` against that lock fails outright ("Required package
# onelogin/php-saml is not present in the lock file"), confirmed by actually
# running it. Removing the stale lock lets composer resolve both
# dependencies fresh from composer.json instead.
RUN rm -f composer.lock \
    && composer install --no-dev --no-interaction --optimize-autoloader \
    && chown -R www-data:www-data /var/www/html

# -----------------------------------------------------------------------------
# Runtime configuration -- ports, vhost, WAF rules, PHP hardening
# -----------------------------------------------------------------------------
# Apache listens on 8080 (matches docker-compose.yml's port mapping and the
# healthcheck in that file, and apache-vhost.conf's <VirtualHost *:8080>).
RUN sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf

COPY docker/apache-vhost.conf /etc/apache2/sites-available/000-default.conf

RUN mkdir -p /etc/modsecurity
COPY docker/modsecurity/modsecurity.conf              /etc/modsecurity/modsecurity.conf
COPY docker/modsecurity/modsecurity.conf-recommended   /etc/modsecurity/modsecurity.conf-recommended
COPY docker/modsecurity/lockdown-whitelist.conf         /etc/modsecurity/lockdown-whitelist.conf
COPY docker/modsecurity/scanner-detection.conf          /etc/modsecurity/scanner-detection.conf
COPY docker/modsecurity/grc-assessment-rules.conf        /etc/modsecurity/grc-assessment-rules.conf
# Load the custom rule files alongside the core ModSecurity config. The
# vendor's base image presumably wires this into its own modsecurity.conf
# or a conf.d snippet; reconstructing that wiring explicitly here so the
# custom rules actually load rather than sitting unused on disk.
RUN { \
        echo 'IncludeOptional /etc/modsecurity/lockdown-whitelist.conf'; \
        echo 'IncludeOptional /etc/modsecurity/scanner-detection.conf'; \
        echo 'IncludeOptional /etc/modsecurity/grc-assessment-rules.conf'; \
    } >> /etc/modsecurity/modsecurity.conf \
    && ln -sf /etc/modsecurity/modsecurity.conf /etc/modsecurity/modsecurity.conf-enabled 2>/dev/null || true

# php-hardening.ini's own header comment documents this exact symlink target
# (see docker/php-hardening.ini) -- applying it to both the Apache and CLI
# SAPIs, since cron jobs run PHP via the CLI SAPI, not Apache.
COPY docker/php-hardening.ini /etc/php/8.3/apache2/conf.d/99-hardening.ini
COPY docker/php-hardening.ini /etc/php/8.3/cli/conf.d/99-hardening.ini
# open_basedir in that file allowlists /var/log/php -- make sure it exists.
RUN mkdir -p /var/log/php && chown www-data:www-data /var/log/php

COPY docker/fairtprm-tuning.cnf /etc/mysql/mariadb.conf.d/99-fairtprm-tuning.cnf
COPY docker/clamd.conf /etc/clamav/clamd.conf
COPY docker/crontab /etc/cron.d/open-tprm
RUN chmod 0644 /etc/cron.d/open-tprm

# -----------------------------------------------------------------------------
# First-boot ClamAV signature seed. freshclam normally fetches these at
# container start, but that can take a few minutes on a fresh VPS with a slow
# link, during which uploads fail closed (see entrypoint.sh's comment on this
# exact trade-off). Pre-seeding here means signatures are ready immediately.
# Non-fatal if it fails during build (offline builder, rate-limited mirror);
# freshclam will just fetch them on first container start instead.
# -----------------------------------------------------------------------------
RUN freshclam --quiet || echo "freshclam pre-seed skipped, will fetch at first container start"

# -----------------------------------------------------------------------------
# Entrypoint -- unmodified from the vendor's image. It handles first-run
# MariaDB init, schema + migration loading, admin password generation,
# persistent/ population, WAF config restore, cron sync, ClamAV startup, and
# finally execs Apache in the foreground as PID 1.
# -----------------------------------------------------------------------------
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080
VOLUME ["/persistent", "/var/lib/mysql"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
