<!-- Short, focused guidance for AI coding agents working on this repository -->
# Copilot instructions — drupal-cms-docker

This repository builds a single Docker image containing a production-ready Drupal CMS (PHP-FPM + Nginx) and runs it together with Postgres via Docker Compose. Keep instructions concise and reference the files below when making changes.

Key files to read first:
- `Dockerfile` — multi-stage build (stages: `builder`, `drupal_app_base`, `final`). Composer runs in `builder` (copies over `composer.json` & `composer.lock` and runs `composer install`).
- `docker-compose.yml` (and `.dev.yml`) — defines two services: `drupal` (built from this repo, image `ttrelvik/drupal-core:[tag]`) and `db` (Postgres 16 with `pgvector`). Volume mappings and env vars live here.
- `.docker/entrypoint.sh` — starts `php-fpm` and `nginx`, symlinks Nginx logs to stdout/stderr.
- `.docker/nginx/default.conf` — Nginx config (root `/app/web`, `fastcgi_pass 127.0.0.1:9000`).

Big-picture architecture (what to expect):
- Single container runs both PHP-FPM and Nginx (started by `entrypoint.sh`). Nginx communicates with PHP-FPM over `127.0.0.1:9000` as configured in `default.conf`.
- The image is produced by a multi-stage Dockerfile: the `builder` stage runs Composer and installs modules; `drupal_app_base` installs system packages & PHP extensions; `final` copies the built app and runtime config.
- Persistent data: `docker-compose.yml` exposes two volumes: `db_data` (Postgres DB data) and `sites_default` mounted at `/app/web/sites/default`.

Developer workflows & STRICT COMMAND RULES:
- **FORBIDDEN:** Never suggest running Composer or Drush commands directly on the host. We use a Docker Swarm workflow, not Docker Compose for the running architecture.
- **ALWAYS wrap Composer commands** in the tools container syntax to use Ghost Volumes:
  ```bash
  docker compose -f docker-compose.tools.yml run --rm composer composer <command> --ignore-platform-reqs
  ```
- **ALWAYS wrap Drush commands** by explicitly targeting the running container using `docker exec` (via `docker ps` evaluation):
  ```bash
  docker exec -it $(docker ps -qf name=drupal-dev_drupal) drush <command>
  ```
- **Building and Deploying**: Ensure instructions leverage the standard Swarm deployment mechanisms rather than local compose builds:
  ```bash
  docker build -t ttrelvik/drupal-core:[tag] .
  docker stack deploy -c docker-compose.dev.yml drupal-dev
  ```
- **Viewing Logs**: Check the logs against the Swarm service, rather than the compose container:
  ```bash
  docker service logs -f drupal-dev_drupal
  ```

Adding and Removing Modules:
- **Adding a Module:**
  ```bash
  docker compose -f docker-compose.tools.yml run --rm composer composer require <package> --ignore-platform-reqs
  ```
- **Removing a Module:**
  You must uninstall it via Drush FIRST in the running container, then remove it via Composer:
  ```bash
  docker exec -it $(docker ps -qf name=drupal-dev_drupal) drush pmu <module_name>
  docker compose -f docker-compose.tools.yml run --rm composer composer remove <package> --ignore-platform-reqs
  ```

Project-specific conventions and gotchas (do not assume defaults):
- To add contributed modules permanently to the image, run `composer require` via the tools container. This updates `composer.json` & `composer.lock`. Then rebuild the stack (`docker build -t ttrelvik/drupal-core:[tag] .` and `docker stack deploy`), which will copy the new lockfile into the `builder` stage of the `Dockerfile` and install the new dependencies during build.
- If you need system packages or PHP extensions for modules, update both the `builder` and `drupal_app_base` stages (`apt-get install` and `docker-php-ext-install`) so build-time and runtime environments match.
- The `docker-compose` service `drupal` mounts `sites_default` at `/app/web/sites/default`. A freshly mounted, empty volume will hide files baked into the image. Inspect the directory before installing, e.g. `docker exec -it $(docker ps -qf name=drupal-dev_drupal) sh -c "ls -la /app/web/sites/default"`.
- Nginx expects PHP-FPM at `127.0.0.1:9000` (see `.docker/nginx/default.conf`). Any change to how PHP-FPM listens must be coordinated with this file or with the entrypoint.
  - The entrypoint uses `php-fpm -D` (note the command name) and symlinks Nginx logs to stdout/stderr — prefer `docker service logs` for quick debugging.

Integration points & concrete values:
-- Postgres connection (used during Drupal install):
  - Host: `db`
  - Database: value of `POSTGRES_DB` in `.env` (default: `drupal`)
  - User: value of `POSTGRES_USER` in `.env` (default: `drupal`)
  - Password: value of `POSTGRES_PASSWORD` in `.env`
  (Define canonical `POSTGRES_*` variables once in `.env` or copy from `.env.example`; `docker-compose.yml` maps them into the Drupal container as `DB_*`.)

When editing code or containers, prefer the smallest, verifiable change:
- If you change the Dockerfile, rebuild with `docker build` and redeploy using `docker stack deploy`. Confirm the site behavior and check `docker service logs`.
- If adding packages, update both build/runtime stages and run a full rebuild.

What is not present / not discoverable here:
- There are no CI config files or automated tests in this repo. If you see references to CI in other notes, verify by searching for `.github/workflows` or similar.

If anything in these files looks ambiguous (e.g., PHP-FPM listen mode, first-run population of `sites/default`), ask for clarification or reproduce the environment locally to inspect paths.

Examples (quick edits):
- Add a PHP extension: edit both stages in `Dockerfile` and add the `docker-php-ext-install` line in each. Rebuild.
- Add a module: `docker compose -f docker-compose.tools.yml run --rm composer composer require 'drupal/example'` then rebuild and redeploy the image.

Questions for the maintainer (if unclear):
- Should the `sites/default` volume be pre-populated on first-run? If yes, provide the preferred seeding step.
- Note: There are currently no automated CI/CD pipelines. All image builds and pushes are manual, and explicit tags are used for Swarm services.

End of guidance — ask for clarification if anything above is out of date.
