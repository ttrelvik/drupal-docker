#!/bin/bash

# refresh-prod.sh
# Orchestrates the refresh/update of the production Drupal stack and handles DB updates/cache rebuilds.

set -e

echo "========================================"
echo " Preparing Production Refresh/Deploy"
echo "========================================"

# Git Branch Check
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo -e "\033[1;31mError: You are not on the 'main' branch (current branch: $CURRENT_BRANCH).\033[0m"
  echo "Please switch to the 'main' branch to deploy to production."
  exit 1
fi

# Git Status Check: Ensure no uncommitted changes for reproducible deploys
if ! git diff-index --quiet HEAD --; then
  echo -e "\033[1;33mError: There are uncommitted changes in the repository.\033[0m"
  echo "Please commit or stash your changes before refreshing production."
  exit 1
fi

# Confirmation Prompt
echo -e "\033[1;31mWARNING: You are about to deploy/refresh the PRODUCTION environment.\033[0m"
read -p "Are you sure you want to proceed? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborting."
    exit 1
fi

# Maintenance Mode Toggle (Pre-Deploy)
echo "Evaluating container status..."
# Grab the very first container ID matching the name, in case multiple exist during a rolling start
EXISTING_CONTAINER=$(docker ps -qf name=drupal_drupal | head -n 1)

if [ ! -z "$EXISTING_CONTAINER" ]; then
    echo "Putting existing site into maintenance mode..."
    docker exec -it "$EXISTING_CONTAINER" drush state:set system.maintenance_mode 1 -y
    docker exec -it "$EXISTING_CONTAINER" drush cr
else
    echo "No running drupal container found. Skipping maintenance mode setup."
fi

echo "========================================"
echo " Deploying Stack"
echo "========================================"

# Deploy Production Stack and wait for convergence
docker stack deploy -c docker-compose.yml drupal --detach=false

echo "========================================"
echo " Waiting for Container & Drush"
echo "========================================"

MAX_RETRIES=60
WAIT_TIME=5
RETRY_COUNT=0
NEW_CONTAINER_ID=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Always grab the first matching container. Since we waited for convergence,
    # the old container is gone and this will be the currently running one.
    NEW_CONTAINER_ID=$(docker ps -qf name=drupal_drupal -f status=running | head -n 1)
    
    if [ ! -z "$NEW_CONTAINER_ID" ]; then
        # Container is up, now check if drush is ready
        # Disable set -e temporarily for the health check
        set +e
        docker exec -t "$NEW_CONTAINER_ID" drush status > /dev/null 2>&1
        DRUSH_STATUS=$?
        set -e

        if [ $DRUSH_STATUS -eq 0 ]; then
            echo "Container and Drush are ready!"
            break
        fi
    fi
    
    echo "Still waiting for container/drush readiness (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
    sleep "$WAIT_TIME"
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "\033[1;31mError: Timed out waiting for the container and Drush to become ready.\033[0m"
    echo "Please check the container logs manually."
    exit 1
fi

echo "========================================"
echo " Running Updates & Clearing Cache"
echo "========================================"

echo "Running database updates..."
docker exec -it "$NEW_CONTAINER_ID" drush updb -y

echo "Taking site out of maintenance mode..."
docker exec -it "$NEW_CONTAINER_ID" drush state:set system.maintenance_mode 0 -y

echo "Clearing cache..."
docker exec -it "$NEW_CONTAINER_ID" drush cr

echo "========================================"
echo -e "\033[1;32m✅ Production environment successfully refreshed.\033[0m"
echo "========================================"
