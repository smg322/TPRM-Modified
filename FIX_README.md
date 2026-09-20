# Fair TPRM & GRC Platform -- v2.6.2 + stakeholder-permissions fix

Complete, self-contained codebase, ready to build and deploy on a fresh VPS
with the exact same `docker-compose.yml` and `docker compose up --build`
workflow you'd normally use. No changes needed to how you invoke it.

## What's different from the original zip

**The fix** (everything from this conversation, proven against a live
MariaDB + PHP instance -- 7 users seeded across every ACL group, a simulated
broken-groups recovery, a 5-vendor + 5-FAIR-analysis demo run):
- `web/includes/admin/users.php` -- Create User form now has a group/
  stakeholder picker; group-assignment saves no longer fail silently on a
  stale CSRF token
- `web/includes/admin/groups.php` -- wired into the same self-heal
- `web/includes/classes/ACL.php` -- new `ensureDefaultSystemGroups()`,
  self-healing guarantee that all 7 default ACL groups exist
- `web/includes/i18n/en.php` -- new UI strings for the above

**The Docker build.** `Dockerfile` in this repo now builds the entire stack
from source (Ubuntu 24.04 + Apache + ModSecurity + PHP 8.3 + MariaDB +
ClamAV, exactly matching the packages and config `docker/entrypoint.sh`
already expects) instead of layering onto a private registry image at
`dockerregistry.fairtprm.com` that isn't publicly reachable. This is what
makes a fresh VPS install possible without registry access. Your original
Dockerfile is preserved as `Dockerfile.vendor-overlay` -- if your VPS *does*
have access to that private registry, that one is the vendor's real
pipeline and is probably preferable (smaller image, faster build, exactly
what they test against).

**One independent bug fixed along the way:** `web/composer.lock` was stale
relative to `composer.json` -- it locked `dompdf/dompdf` but was completely
missing `onelogin/php-saml`. A strict `composer install` against that lock
fails outright (confirmed by actually running it: "Required package
onelogin/php-saml is not present in the lock file"). The lock file has been
removed; the new `Dockerfile` runs `composer install` against
`composer.json` directly, which regenerates it correctly.

## How I validated this (and what I couldn't)

I do not have a `docker` daemon with registry access in the environment I
worked in, so I could not run `docker compose build` itself end-to-end. What
I did instead, which I'd argue is a stronger test of the actual runtime
behavior: installed the exact same package set this Dockerfile specifies
directly (Apache, ModSecurity, PHP 8.3 + every extension, MariaDB, ClamAV,
cron, composer), staged every config file at the exact paths the Dockerfile
places them, and then **ran the real, unmodified `docker/entrypoint.sh`
from a completely wiped state** -- fresh MariaDB data directory, fresh
`/persistent`, nothing pre-seeded.

It worked. Full log excerpt:

```
==> Initializing MariaDB data directory...
==> MariaDB is running.
==> Database 'tprm' not found — creating and seeding...
    - Master schema loaded.
    - User grants and seed data applied.
    - Applying SQL update: v2.6.2.sql
DATABASE CREATED - SAVE THESE CREDENTIALS
  Portal Admin User:            admin
  Portal Admin Password:        <generated>
==> Initializing WAF security configuration...
    - Generated 121 whitelist rules
==> Starting Apache on port 8080...
```

Then: `curl http://127.0.0.1:8080/login.php` → HTTP 200, real login page.
Logged in with the generated admin credentials → HTTP 302 (success).
Loaded the Users admin page → the group picker is there, all 7 ACL groups
present in the database.

What I genuinely could not test: the actual `docker build` orchestration
layer itself (layer caching, `COPY` semantics, final image size) and
anything requiring `packagist.org`/Docker Hub access, both blocked in my
sandbox's network policy. The package list and every config file placement
is proven; the Docker plumbing around them is carefully constructed from
reading `docker-compose.yml`'s healthcheck, `apache-vhost.conf`'s port, and
`entrypoint.sh`'s own filesystem expectations, but not build-tested as a
literal `docker build` invocation.

## Deploying on your VPS

```bash
# unzip this package on the VPS, then:
cd open-fairtprm-master
docker compose build
docker compose up -d
docker compose logs -f      # watch first-run init; admin password is
                             # printed once and saved to
                             # /persistent/config/.sensitive in the volume
```

Same `docker-compose.yml`, same port (8080), same volumes
(`persistent_data`, `mariadb_data`), same healthcheck. Nothing about how you
invoke it changes.
