# Drupal Docker Project

This project builds a **production-ready, CI/CD-friendly Docker image** for Tom Trelvik's Drupal portfolio site. It is designed to run in a **Docker Swarm** environment with **Traefik** as the ingress controller.

---

## 🏗️ Architecture & Infrastructure

The project runs a multi-container stack defined by a Configuration-as-Code strategy.

### Services
- **Drupal Core (`drupal-core`)**: A custom PHP 8.4 application image based on `php:8.4-fpm-bookworm` bundled with Nginx. Active configuration files and the custom [settings.local.php](file:///home/ttrelvik/services/drupal-docker/.docker/drupal/settings.local.php) are compiled directly into the image at build time via the [Dockerfile](file:///home/ttrelvik/services/drupal-docker/Dockerfile).
  - *Current Production Tag:* `ttrelvik/drupal-core:beta21`
- **Database (`db`)**: PostgreSQL 16 with the `pgvector` extension (`pgvector/pgvector:0.8.2-pg16-trixie`) for storing system schemas and managing AI vector embeddings.

### Networking
The stack leverages two Docker networks to isolate traffic and handle routing:
- **`drupal_net` / `drupal_net_dev`**: An overlay network that facilitates secure, internal communication between the Drupal application container and the PostgreSQL database container.
- **`traefik-net`**: An external overlay network that connects the running Drupal container to the Traefik ingress load balancer. Traefik routes inbound HTTPS traffic to the Nginx service on port 80.

### Persistent Volumes
To ensure data preservation across container updates and restarts, the architecture relies on two persistent volume mounts:
- **`sites_default`**: Mounted at `/app/web/sites/default` inside the Drupal container. This persists dynamically uploaded files (such as user uploads and media assets) while the codebase and configuration remain burned into the image.
- **`db_data`**: Mounted at `/var/lib/postgresql/data` inside the database container. This persists the active PostgreSQL database state.

---

## 🛠️ Tri-Compose Architecture

The repository leverages three Docker Compose files to segregate execution scopes cleanly:

1. **[docker-compose.yml](file:///home/ttrelvik/services/drupal-docker/docker-compose.yml)**: The production stack definition. Deployed via:
   ```bash
   docker stack deploy -c docker-compose.yml drupal
   ```
2. **[docker-compose.dev.yml](file:///home/ttrelvik/services/drupal-docker/docker-compose.dev.yml)**: The development stack definition. It mirrors the production architecture but binds development secrets, runs on isolated dev networks, and targets the dev subdomain. Deployed via:
   ```bash
   docker stack deploy -c docker-compose.dev.yml drupal-dev
   ```
3. **[docker-compose.tools.yml](file:///home/ttrelvik/services/drupal-docker/docker-compose.tools.yml)**: A dedicated configuration for running short-lived, one-off utility tasks (e.g., executing dependency management tasks via Composer) on the host without local environment pollution.

---

## 🔑 Setup & Secret Configuration

The environment utilizes distinct files for production and development:
- **Production**: Uses `.env` (targets `blog.trelvik.net` and production secret sources).
- **Development**: Uses `dev.env` (targets `dev-blog.trelvik.net` and development secret sources).

### Docker Secrets Setup
Before launching the stacks, the required external Docker secrets must exist in the Swarm cluster. 

To ensure credentials are never stored in plaintext on disk or recorded in the terminal's command history, create them by reading from standard input (stdin) using the `-` flag. Paste the secret value, press `<enter>`, and then press `Ctrl+D` to finalize:

#### For Production Stack:
```bash
docker secret create drupal_postgres_password -
docker secret create gemini_api_key -
docker secret create openai_api_key -
```

#### For Development Stack:
```bash
docker secret create drupal-dev_postgres_password -
# Gemini and OpenAI API keys can be shared across environments or isolated
```

---

## 🔄 Development Workflows

### 1. Manual Dependency Management & "Ghost Volumes"
We manage dependencies using the `composer` service defined in [docker-compose.tools.yml](file:///home/ttrelvik/services/drupal-docker/docker-compose.tools.yml). This setup uses anonymous **"Ghost Volumes"** (e.g., `/app/vendor/`, `/app/web/modules/contrib/`) to avoid writing thousands of compiled PHP files back onto the host machine during package manipulation.

- **Adding a Module:**
  ```bash
  docker compose -f docker-compose.tools.yml run --rm composer composer require <package> --ignore-platform-reqs
  ```

- **Removing a Module:**
  You must uninstall the module inside the running container first before stripping the dependency:
  ```bash
  # 1. Disable/uninstall in the running development container
  docker exec -it $(docker ps -qf name=drupal-dev_drupal) drush pmu <module_name>

  # 2. Remove the dependency and update the lockfile via the tools container
  docker compose -f docker-compose.tools.yml run --rm composer composer remove <package> --ignore-platform-reqs
  ```

### 2. Configuration Export Workflow
When you perform administrative adjustments via the Drupal GUI on the running Dev stack (e.g., editing fields, adjusting view structures), export the configuration and copy it back to the host repository so it is built into the next Docker image:

1. **Export active config in the Dev container:**
   ```bash
   docker exec -it $(docker ps -qf name=drupal-dev_drupal) drush cex -y
   ```
2. **Copy configuration files from container to host:**
   ```bash
   docker cp $(docker ps -qf name=drupal-dev_drupal):/app/config/sync/. ./config/
   ```
3. **Commit the exported configs to Git:**
   ```bash
   git add config/
   git commit -m "feat: export config updates"
   ```

### 3. Configuration Import & Post-Deployment (`config-import.sh`)
The custom [config-import.sh](file:///home/ttrelvik/services/drupal-docker/config-import.sh) script handles importing configuration updates, updating environment-specific AI system prompts, and rebuilding the search API search indexes. Execute it inside the running container following a stack refresh:

- **For Dev Environment:**
  ```bash
  docker exec -it $(docker ps -qf name=drupal-dev_drupal) /app/config-import.sh dev-blog.trelvik.net
  ```
- **For Production Environment:**
  ```bash
  docker exec -it $(docker ps -qf name=drupal_drupal) /app/config-import.sh blog.trelvik.net
  ```

---

## 🤖 Renovate Bot Update & Deployment Pipeline

We use **Renovate Bot** (configured in [renovate.json](file:///home/ttrelvik/services/drupal-docker/renovate.json)) to automate updates. Renovate pins database and system base images (such as pinning PostgreSQL minor/patch versions) and bundles PHP/Drupal package updates into a single grouped Composer Suite PR.

Follow this step-by-step pipeline to apply and verify these automated updates:

### 1. Automated PR Discovery
Renovate Bot automatically flags infrastructure updates or creates a unified, single branch combining all PHP and Drupal module/lockfile updates (e.g., `renovate/composer-packages`).

### 2. Local Checkout
Pull down the Renovate feature tracking branch on your host machine to capture the lockfile modifications:
```bash
git fetch origin
git checkout renovate/composer-packages
```

### 3. Build & Test in Dev
Assign a new tracking milestone/release tag (e.g., `beta22`) and run the development deployment script. This pulls the bot's modified `composer.lock` straight into the custom core image build sequence:
```bash
./deploy-dev.sh betaXX
```
> [!NOTE]
> The [deploy-dev.sh](file:///home/ttrelvik/services/drupal-docker/deploy-dev.sh) script handles tag-prefixing intelligently. When running on the `main` branch or any branch starting with `renovate/` (such as `renovate/composer-packages`), it preserves the exact literal tag (e.g., `betaXX`) to build and test production candidate images. On any other standard feature branches, it automatically prepends `dev-` (resulting in `dev-betaXX`) to prevent tag clashes. The script then orchestrates building/pushing the image, toggling maintenance mode, deploying the dev stack, executing database updates (`drush updb`), and clearing caches.

### 4. Dev Environment Audit
Manually check and verify stack stability on the development site at `https://dev-blog.trelvik.net`.

### 5. Atomic Production Tag Update
If the dev stack tests clean, manually update the `drupal-core` image tag version in [docker-compose.yml](file:///home/ttrelvik/services/drupal-docker/docker-compose.yml) to match the updated tag in [docker-compose.dev.yml](file:///home/ttrelvik/services/drupal-docker/docker-compose.dev.yml).

### 6. Commit the Tag Alignment
Commit and push the configuration changes to the feature branch. This ensures tracking updates remain atomic within the PR, align with dev reality, and pass the uncommitted change checks in the production deployment script:
```bash
git add docker-compose.yml docker-compose.dev.yml
git commit -m "chore: bump core to betaXX and consume updates"
git push origin renovate/composer-packages
```

### 7. Terminal Merge via GitHub CLI
Merge the pull request directly from your terminal using the GitHub CLI:
```bash
gh pr merge --merge --delete-branch
```

### 8. Production Go-Live
Switch back to your local `main` branch, pull down the synchronized merge commits, and execute the production release pipeline script:
```bash
git checkout main
git pull
./refresh-prod.sh
```
> [!NOTE]
> The [refresh-prod.sh](file:///home/ttrelvik/services/drupal-docker/refresh-prod.sh) script verifies that you are on `main`, checks for uncommitted changes, prompts for confirmation, turns on maintenance mode, deploys the stack, waits for container convergence, executes database migrations, turns off maintenance mode, and rebuilds the production cache.

### 9. Native Extension Database Synchronization
If the update involved a database image tag bump (such as upgrading the `pgvector` container from `0.8.1` to `0.8.2`), you must update the database schema metadata inside the running container to map the updated database filesystem binaries onto active schema definitions:
```bash
docker exec -it $(docker ps -qf name=drupal_db) psql -U drupal -d drupal -c "ALTER EXTENSION vector UPDATE;"
```

### 10. Final Verification
Perform a final sanity check of the live website at `https://blog.trelvik.net`.

---

## 📦 Backup & Restore

The repository provides automated helper scripts to manage data backups and stack refreshes.

### `backup.sh` (Production Backup)
Creates a full backup of the **Production** site database and files. The [backup.sh](file:///home/ttrelvik/services/drupal-docker/backup.sh) script:
- Toggles Drupal into Maintenance Mode.
- Dumps the PostgreSQL database (including vectors).
- Compresses the `web/sites/default/files` directory.
- Restores the site to online status and saves the compressed archive inside the host's `backups/` directory.

Run it on the host via:
```bash
./backup.sh
```

### `restore.sh` (Restore to Stack)
Restores an existing backup archive to a target environment stack (e.g., syncing production data down to dev). The [restore.sh](file:///home/ttrelvik/services/drupal-docker/restore.sh) script:
- Searches for and utilizes the latest backup archive inside `backups/`.
- Drops and regenerates the database schema.
- Re-populates the persistent files directory.
- Triggers pending database migrations (`drush updb`).

To restore the latest backup to the development stack, run:
```bash
./restore.sh drupal-dev
```
