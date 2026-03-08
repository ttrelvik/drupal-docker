#!/bin/bash
set -e

# --- CONFIGURATION ---
CONTAINER_FILTER="^drupal_drupal"
BACKUP_DIR_BASE="./backups"
BACKUP_FILENAME="drupal-backup.tar.gz"
BACKUP_DEST_IN_CONTAINER="/tmp/$BACKUP_FILENAME"

# --- HELPER FUNCTIONS ---
get_container_id() {
  local id
  id=$(docker ps -q --filter "name=${CONTAINER_FILTER}" | head -n 1)
  if [ -z "$id" ]; then
    echo "Error: Could not find a running container with filter '${CONTAINER_FILTER}'." >&2
    exit 1
  fi
  echo "$id"
}

run_in_container() {
  docker exec "$(get_container_id)" "$@"
}

cleanup() {
  echo "Running cleanup: Disabling maintenance mode..."
  run_in_container drush sset system.maintenance_mode 0 -y || echo "Failed to disable maintenance mode."
}

# --- TRAP ---
trap 'echo "An error occurred." >&2; cleanup; exit 1' ERR

# --- MAIN LOGIC ---
echo "Starting backup process..."

echo "Enabling maintenance mode..."
run_in_container drush sset system.maintenance_mode 1 -y

echo "Creating archive dump inside the container..."
run_in_container drush archive:dump --overwrite --db --files --destination=$BACKUP_DEST_IN_CONTAINER --extra-dump=--no-owner -y

echo "Copying archive from container to host..."
# Create timestamped directory here to ensure it only gets created on successful backup
BACKUP_DIR="$BACKUP_DIR_BASE/$(date +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$BACKUP_DIR"
# Copy the file from the container to the host
docker exec "$(get_container_id)" cat "$BACKUP_DEST_IN_CONTAINER" > "$BACKUP_DIR/$BACKUP_FILENAME"

echo "Cleaning up temporary archive file in container..."
run_in_container rm -f "$BACKUP_DEST_IN_CONTAINER"

# --- FINAL CLEANUP ---
cleanup
trap - ERR

echo "✅ Backup complete! Archive is in: $BACKUP_DIR"