#!/bin/bash
set -e

# Deploy script for configuring the imported Drupal site
# including the AI Agent settings and re-indexing site content.
#
# Usage: ./deploy.sh [target_domain]

# Default to Production domain if no argument is provided
TARGET_DOMAIN=${1:-"blog.trelvik.net"}

echo "🚀 Starting Deployment..."
echo "Target Domain for AI Agent: $TARGET_DOMAIN"

# 1. Import the Configuration
# This brings the database in sync with your YAML files (enabling OpenAI, adding fields, etc.)
echo "Importing site configuration..."
drush config:import -y

# 2. Environment Override: Update the AI System Prompt
# We look for the placeholder domain (dev-blog) and replace it with the target.
echo "Configuring AI Agent..."
CURRENT_PROMPT=$(drush config:get ai_agents.ai_agent.portfolio_advocate system_prompt --include-overridden --format=string)

# Replace 'dev-blog.trelvik.net' with the dynamic TARGET_DOMAIN
NEW_PROMPT="${CURRENT_PROMPT//dev-blog.trelvik.net/$TARGET_DOMAIN}"

drush config:set ai_agents.ai_agent.portfolio_advocate system_prompt "$NEW_PROMPT" -y

# 3. Re-index Content
echo "Indexing content for RAG..."
drush search-api:index

echo "✅ Deployment complete!"