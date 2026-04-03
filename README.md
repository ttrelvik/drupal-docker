# Drupal Docker Project

This project builds a **production-ready, CI/CD-friendly Docker image** for Tom Trelvik's Drupal portfolio site. It is designed to run in a **Docker Swarm** environment with **Traefik** as the ingress controller.

## ✅ Architecture

- **Base Image**: `drupal/recommended-project` (via `php:8.4-fpm-bookworm`)
- **Web Server**: Nginx (bundled in the same image for simplicity)
- **Database**: PostgreSQL 16 with `pgvector` extension (for AI embeddings)
- **Orchestration**: Docker Swarm
- **Ingress**: Traefik (with Let's Encrypt TLS)

## 🚀 Images

The project builds the following image:
- `ttrelvik/drupal-core:beta1` (Current production tag)

This image follows a **Configuration-as-Code** strategy:
- The `config/` directory (exported from active configuration) is **burned into the image** at build time.
- `settings.local.php` is also burned in to handle environment-specific logic (secrets, Trusted Host settings).

---

## 🛠️ Usage & Workflows

### 1. Prerequisites (Docker-First Workflow)
This project prioritizes a **Docker-based workflow** over any local PHP or Composer installation. You do not need PHP or Composer installed on your host machine to manage or run this project.
- Docker & Docker Compose
- Docker Swarm (initialized via `docker swarm init`)
- [Traefik](https://doc.traefik.io/traefik/) running on the swarm (connected to external network `traefik-net`)

### 2. Tri-Compose Architecture
The project leverages three different compose files for different purposes:
- **`docker-compose.yml`**: Used for the running production site (Drupal + Postgres/pgvector). Deployed via `docker stack deploy -c docker-compose.yml drupal`.
- **`docker-compose.dev.yml`**: Used for the running development site. Mirrors production architecture but uses development secrets/domains. Deployed via `docker stack deploy -c docker-compose.dev.yml drupal-dev`.
- **`docker-compose.tools.yml`**: Dedicated solely to one-off development tasks (like dependency management operations via Composer). Deployed via `docker compose -f docker-compose.tools.yml run --rm composer`.

### 3. Dependency Management & The "Ghost Volume" Workflow
We manage dependencies using the `composer` service defined in `docker-compose.tools.yml`. This file employs **"Ghost Volumes"** (anonymous volumes) targeting directories like `/app/vendor/` and `/app/web/modules/contrib/`.

**Why Ghost Volumes?** 
They keep the host machine cleaner by preventing thousands of dependency files from syncing back to the host, while still allowing the tools container to manage and write those dependencies internally to generate an updated `composer.lock` file.

**Adding a Module:**
```bash
docker compose -f docker-compose.tools.yml run --rm composer composer require <package> --ignore-platform-reqs
```

**Removing a Module:**
When removing a module, you must also uninstall it in the running Drupal instance to keep the environment clean.
```bash
# 1. Uninstall in the running container first
docker exec -it $(docker ps -qf name=drupal-dev_drupal) drush pmu <module_name>

# 2. Remove the dependency via the tools container
docker compose -f docker-compose.tools.yml run --rm composer composer remove <package> --ignore-platform-reqs
```

### 4. The Build Pipeline
The deployment lifecycle follows this progression:
1. **Update Blueprint**: Use the tools container to update dependencies, which generates a new `composer.lock` and `composer.json`.
2. **Build Factory**: The build process uses the `Dockerfile` to read the `composer.lock` and build a fresh image containing all required files.
3. **Deploy to Swarm (Production)**: The immutable image is deployed to the Swarm cluster.

### 5. Environment Setup
The project uses distinct environment files for Production vs. Development:
- **Production**: `.env` (References `blog.trelvik.net`, external secrets)
- **Development**: `dev.env` (References `dev-blog.trelvik.net`, development secrets)

### 3. Deploying (Production)
```bash
# 1. Create Secrets (if not existing)
docker secret create drupal_postgres_password ./secret_file
docker secret create gemini_api_key ./key_file
docker secret create openai_api_key ./key_file

# 2. Deploy/Refresh Stack
./refresh-prod.sh
```
*Access:* `https://blog.trelvik.net`

### 4. Deploying (Development)
The development stack runs isolated from production but mirrors its architecture. Use the `deploy-dev.sh` script to build, push, and deploy a new image to the development stack from the `midna` host.

```bash
# 1. Create Dev Secrets (First time only)
docker secret create drupal-dev_postgres_password ./dev_secret_file
# (API keys can be shared or separate)

# 2. Build, Push, and Deploy to Dev Stack
./deploy-dev.sh [tag]
```
*Access:* `https://dev-blog.trelvik.net`

---

## 📦 Backup & Restore

The project includes scripts to manage data persistence and environment synchronization.

### `backup.sh` (Production Backup)
Creates a full backup of the **Production** site (database + file assets).
- Puts site in Maintenance Mode.
- Dumps PostgreSQL database (including vectors).
- Archives `web/sites/default/files`.
- Saves tarball to host `backups/` directory.
```bash
./backup.sh
```

### `restore.sh` (Restore to Any Stack)
Restores a backup tarball to a specified stack (e.g., refreshing Dev with Prod data).
- automatically finds the latest backup.
- **Drops and Re-creates** the database.
- Restores file assets.
- Runs database updates (`drush updb`).
```bash
# Restore latest prod backup to the DEV stack
./restore.sh drupal-dev
```

### Configuration Export Workflow
When you make structural changes to the site via the running Dev container (e.g., adding a field, creating a view via the Drupal GUI), follow this workflow to burn those changes into the Git repository and subsequent Docker builds:

1. **Export the Active Configuration**:
   Exec into the running DEV container to generate the sync files.
   ```bash
   docker exec -it $(docker ps -qf name=drupal-dev_drupal) drush cex -y
   ```
2. **Sync the Configuration to the Host**:
   Because the container's `config/sync` directory is not mounted as a volume, you need to copy the generated YAML files back to your local host folder so they can be committed to Git.
   ```bash
   docker cp $(docker ps -qf name=drupal-dev_drupal):/app/config/sync/. ./config/
   ```
   *Note: We commit the `config/` directory to Git.*
3. **Rebuild the Custom Image**: 
   The `Dockerfile` will ingest the updated `config/` directory during the build process.
   ```bash
   docker build -t ttrelvik/drupal-core:latest .
   ```

### Configuration Import & Post-Deployment (`config-import.sh`)
The codebase includes `/app/config-import.sh` which handles syncing Drupal configuration, updating the AI agent system prompt, and re-indexing site content. This script must be executed **inside** the running Docker container, not from the host:

```bash
docker exec -it $(docker ps -qf name=drupal-dev_drupal) /app/config-import.sh
```

---

## 🔄 Maintenance & Updates

### Updating Drupal & Modules

**IMPORTANT:** Version numbers should **never** be manually edited in `composer.json`. Always use Composer to manage dependencies.

#### Step 1: The Dry Run
Preview updates without changing the `composer.lock` file. This helps identify major version leaps in AI or core libraries before committing to them:
```bash
docker compose -f docker-compose.tools.yml run --rm composer composer update --ignore-platform-reqs --dry-run
```

#### Step 2: The Blueprint Update
Actually execute the update to regenerate the `composer.lock` file with the newest compatible versions:
```bash
docker compose -f docker-compose.tools.yml run --rm composer composer update --ignore-platform-reqs
```

#### Step 3: Targeted Updates
To minimize risk, you can update a single package (e.g., `drupal/core-recommended`) to narrow the scope of the update:
```bash
docker compose -f docker-compose.tools.yml run --rm composer composer update drupal/core-recommended --with-dependencies --ignore-platform-reqs
```

### The "Post-Update" Lifecycle

After making changes to the `composer.lock` utilizing the tools container, you **must** perform the following steps to deploy the update:

1. **Rebuild and push the image with a new tag:** (e.g., `alpha11` or `beta1`)
   ```bash
   docker build -t ttrelvik/drupal-core:beta1 .
   docker push ttrelvik/drupal-core:beta1
   ```

2. **Deploy the stack & Run Updates (Production):**
   Update your `docker-compose.yml` file to reference the new tag if necessary. Then, run the production refresh script. This script safely orchestrates maintenance mode, blocking Swarm deployments, database updates, and cache clearing:
   ```bash
   ./refresh-prod.sh
   ```
   *(For development environments, use `./deploy-dev.sh [tag]` as documented above, which handles the build, push, deployment, and DB updates).*
