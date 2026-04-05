#!/bin/bash

# deploy-dev.sh
# Orchestrates the build, push, and deployment of the Drupal development stack.

set -e

# Require a version tag argument
if [ -z "$1" ]; then
  echo "Error: Version tag is required."
  echo "Usage: $0 <tag>"
  echo "Example: $0 beta1"
  exit 1
fi

TAG="$1"

# Identify current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Git Safety Check: If not on main, prefix tag with 'dev-'
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo -e "\033[1;33mWARNING: You are not on the 'main' branch (current branch: $CURRENT_BRANCH).\033[0m"
  if [[ "$TAG" != dev-* ]]; then
    TAG="dev-$TAG"
    echo -e "\033[1;33mPrefixing tag with 'dev-': New tag is $TAG\033[0m"
  fi
fi

IMAGE_NAME="ttrelvik/drupal-core"
FULL_IMAGE="$IMAGE_NAME:$TAG"

echo "========================================"
echo " Starting Build & Push: $FULL_IMAGE"
echo "========================================"

# Docker Build & Push
docker build -t "$FULL_IMAGE" .
docker push "$FULL_IMAGE"

echo "========================================"
echo " Updating Dev Stack"
echo "========================================"

# Update docker-compose.dev.yml
sed -i -E "s|image: $IMAGE_NAME:.*|image: $FULL_IMAGE|" docker-compose.dev.yml

# Deploy Dev Stack and wait for convergence
docker stack deploy -c docker-compose.dev.yml drupal-dev --detach=false

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
    NEW_CONTAINER_ID=$(docker ps -qf name=drupal-dev_drupal -f status=running | head -n 1)
    
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

echo "Running database updates..."
docker exec -it "$NEW_CONTAINER_ID" drush updb -y

echo "Clearing cache..."
docker exec -it "$NEW_CONTAINER_ID" drush cr

echo "========================================"
echo -e "\033[1;32m✅ Dev stack updated on Midna. To deploy to Prod, manually update docker-compose.yml and redeploy.\033[0m"
echo "========================================"
