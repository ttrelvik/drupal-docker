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

# Deploy Dev Stack
docker stack deploy -c docker-compose.dev.yml drupal-dev

echo "========================================"
echo -e "\033[1;32m✅ Dev stack updated on Midna. To deploy to Prod, manually update docker-compose.prod.yml and redeploy.\033[0m"
echo "========================================"
