#!/bin/bash
set -e

# --- ARGUMENT PARSING ---
if [ -z "$1" ]; then
  echo "Usage: ./restore.sh <stack_name> [path_to_backup_file]"
  echo "Examples:"
  echo "  ./restore.sh drupal-dev"
  echo "  ./restore.sh drupal ./backups/2023-10-27_10-00-00/drupal-backup.tar.gz"
  exit 1
fi

STACK_NAME="$1"
MANUAL_BACKUP_PATH="$2"

# --- CONFIGURATION ---
CONTAINER_FILTER="^${STACK_NAME}_drupal"
BACKUP_FILENAME="drupal-backup.tar.gz"
RESTORE_DEST_IN_CONTAINER="/tmp/$BACKUP_FILENAME"
EXTRACT_DIR="/tmp/restore_temp"
BACKUP_DIR_BASE="./backups"

# --- DETERMINE BACKUP TO RESTORE ---
if [ -n "$MANUAL_BACKUP_PATH" ]; then
  BACKUP_PATH="$MANUAL_BACKUP_PATH"
else
  # Find the most recent backup directory
  LATEST_BACKUP_DIR=$(ls -td "$BACKUP_DIR_BASE"/*/ 2>/dev/null | head -n 1)
  if [ -z "$LATEST_BACKUP_DIR" ]; then
    echo "Error: No backups found in $BACKUP_DIR_BASE"
    exit 1
  fi
  # Remove trailing slash provided by ls -d */
  LATEST_BACKUP_DIR=${LATEST_BACKUP_DIR%/}
  BACKUP_PATH="$LATEST_BACKUP_DIR/$BACKUP_FILENAME"
  echo "Found latest backup: $BACKUP_PATH"
fi

if [ ! -f "$BACKUP_PATH" ]; then
  echo "Error: Backup file not found at $BACKUP_PATH"
  exit 1
fi

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
  docker exec -i "$(get_container_id)" "$@"
}

# --- MAIN LOGIC ---
echo "Starting restore process for stack '$STACK_NAME'..."

echo "Step 1: Preparing settings.php..."
run_in_container cp /app/web/sites/default/default.settings.php /app/web/sites/default/settings.php
run_in_container chmod 664 /app/web/sites/default/settings.php
HASH_SALT=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 55)
run_in_container sh -c 'cat >> /app/web/sites/default/settings.php' <<EOF

\$settings['hash_salt'] = '$HASH_SALT';
EOF

echo "Step 2: Copying backup archive into the container..."
# Copy the file from the host to the container
docker exec -i "$(get_container_id)" sh -c "cat > $RESTORE_DEST_IN_CONTAINER" < "$BACKUP_PATH"

echo "Step 3: Extracting the archive inside the container..."
run_in_container mkdir -p "$EXTRACT_DIR"
run_in_container tar -xzf "$RESTORE_DEST_IN_CONTAINER" -C "$EXTRACT_DIR"

echo "Step 4: Restoring the database..."
run_in_container drush sql:drop -y
run_in_container sh -c "drush sql:cli < $EXTRACT_DIR/database/database.sql"

echo "Step 5: Restoring the files..."
run_in_container rsync -a --delete "$EXTRACT_DIR/files/" /app/web/sites/default/files/

echo "Step 6: Cleaning up temporary files in container..."
run_in_container rm -f "$RESTORE_DEST_IN_CONTAINER"
run_in_container rm -rf "$EXTRACT_DIR"

echo "Step 7: Finalizing the site..."
echo "Setting file permissions..."
run_in_container chown -R www-data:www-data /app/web/sites/default/files
echo "Running database updates..."
run_in_container drush updb -y
echo "Disabling maintenance mode..."
run_in_container drush sset system.maintenance_mode 0 -y
echo "Clearing caches..."
run_in_container drush cr

echo "✅ Restore complete!"
