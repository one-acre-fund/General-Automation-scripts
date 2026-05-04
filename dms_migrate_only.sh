#!/bin/bash
set -uo pipefail

CONFIG_FILE="config.json"

REGION="eu-west-1"

TABLE_MAPPINGS_FILE="table-mappings.json"
TASK_SETTINGS_FILE="task-settings.json"
PASSWORDS_FILE="passwords.json"

TAGS="Key=map-migrated,Value=migFM25HRY5PO"

# ---------------------------
# Lookup replication instance ARN by "dms-" prefix
# ---------------------------
get_replication_instance_arn() {
  aws dms describe-replication-instances \
    --region "$REGION" \
    --no-cli-pager \
    | jq -r '.ReplicationInstances[] | select(.ReplicationInstanceIdentifier | startswith("dms-")) | .ReplicationInstanceArn' \
    | head -1
}

endpoint_exists() {
  local endpoint_id="$1"
  local count
  count=$(aws dms describe-endpoints \
    --filters "Name=endpoint-id,Values=$endpoint_id" \
    --region "$REGION" \
    --no-cli-pager \
    | jq '.Endpoints | length')
  [ "$count" -gt 0 ]
}

get_endpoint_arn() {
  local endpoint_id="$1"
  aws dms describe-endpoints \
    --filters "Name=endpoint-id,Values=$endpoint_id" \
    --region "$REGION" \
    --no-cli-pager \
    | jq -r '.Endpoints[0].EndpointArn'
}

task_exists() {
  local task_id="$1"
  local count
  count=$(aws dms describe-replication-tasks \
    --filters "Name=replication-task-id,Values=$task_id" \
    --region "$REGION" \
    --no-cli-pager \
    | jq '.ReplicationTasks | length')
  [ "$count" -gt 0 ]
}

# ---------------------------
# Resolve replication instance
# ---------------------------
REPLICATION_INSTANCE_ARN=$(get_replication_instance_arn)
if [ -z "$REPLICATION_INSTANCE_ARN" ]; then
  echo "ERROR: No replication instance found with prefix 'dms-'. Exiting."
  exit 1
fi
echo "Using replication instance: $REPLICATION_INSTANCE_ARN"

# ---------------------------
# Main loop
# ---------------------------
jq -c '.servers[]' "$CONFIG_FILE" | while read -r server; do
  SRC_SERVER_NAME=$(echo "$server" | jq -r '.source_server_name')
  TGT_SERVER_NAME=$(echo "$server" | jq -r '.target_server_name')
  echo "Processing: Azure-${SRC_SERVER_NAME} → AWS-${TGT_SERVER_NAME}"

  echo "$server" | jq -c '.databases[]' | while read -r db; do
    DB_NAME=$(echo "$db" | jq -r '.name')
    SOURCE_PASSWORD=$(jq -r --arg srv "$SRC_SERVER_NAME" '.[$srv]' "$PASSWORDS_FILE")
    TARGET_PASSWORD=$(jq -r --arg srv "$TGT_SERVER_NAME" '.[$srv]' "$PASSWORDS_FILE")
    if [ -z "$SOURCE_PASSWORD" ] || [ "$SOURCE_PASSWORD" = "null" ]; then
      echo "ERROR: No password found for '$SRC_SERVER_NAME' in $PASSWORDS_FILE. Skipping."
      continue
    fi
    if [ -z "$TARGET_PASSWORD" ] || [ "$TARGET_PASSWORD" = "null" ]; then
      echo "ERROR: No password found for '$TGT_SERVER_NAME' in $PASSWORDS_FILE. Skipping."
      continue
    fi

    # Source endpoint details
    SRC_HOST=$(echo "$db" | jq -r '.source_endpoint.host')
    SRC_PORT=$(echo "$db" | jq -r '.source_endpoint.port')
    SRC_USER=$(echo "$db" | jq -r '.source_endpoint.username')
    SRC_ENGINE=$(echo "$db" | jq -r '.source_endpoint.engine_name // "sqlserver"')
    SRC_DBNAME=$(echo "$db" | jq -r '.source_endpoint.database_name // empty')
    SRC_SSL_MODE=$(echo "$db" | jq -r '.source_endpoint.ssl_mode // empty')
    SRC_EXTRA=$(echo "$db" | jq -r '.source_endpoint.extra_connection_attributes // empty')

    # Target endpoint details
    TGT_HOST=$(echo "$db" | jq -r '.target_endpoint.host')
    TGT_PORT=$(echo "$db" | jq -r '.target_endpoint.port')
    TGT_USER=$(echo "$db" | jq -r '.target_endpoint.username')
    TGT_ENGINE=$(echo "$db" | jq -r '.target_endpoint.engine_name // "sqlserver"')
    TGT_DBNAME=$(echo "$db" | jq -r '.target_endpoint.database_name // empty')
    TGT_SSL_MODE=$(echo "$db" | jq -r '.target_endpoint.ssl_mode // empty')
    TGT_EXTRA=$(echo "$db" | jq -r '.target_endpoint.extra_connection_attributes // empty')

    # Naming convention
    SOURCE_ENDPOINT_NAME="Azure-${SRC_SERVER_NAME}-AWS-${TGT_SERVER_NAME}-DB-${DB_NAME}-source"
    TARGET_ENDPOINT_NAME="Azure-${SRC_SERVER_NAME}-AWS-${TGT_SERVER_NAME}-DB-${DB_NAME}-target"
    TASK_NAME="Azure-${SRC_SERVER_NAME}-AWS-${TGT_SERVER_NAME}-DB-${DB_NAME}-task"

    # Create source endpoint if not exists
    if endpoint_exists "$SOURCE_ENDPOINT_NAME"; then
      echo "Source endpoint $SOURCE_ENDPOINT_NAME already exists. Skipping creation."
    else
      echo "Creating source endpoint: $SOURCE_ENDPOINT_NAME"
      aws dms create-endpoint \
        --endpoint-identifier "$SOURCE_ENDPOINT_NAME" \
        --endpoint-type source \
        --engine-name "$SRC_ENGINE" \
        --username "$SRC_USER" \
        --password "$SOURCE_PASSWORD" \
        --server-name "$SRC_HOST" \
        --port "$SRC_PORT" \
        --database-name "$SRC_DBNAME" \
        ${SRC_SSL_MODE:+--ssl-mode "$SRC_SSL_MODE"} \
        ${SRC_EXTRA:+--extra-connection-attributes "$SRC_EXTRA"} \
        --tags "$TAGS" \
        --no-cli-pager \
        --region "$REGION"
    fi

    # Create target endpoint if not exists
    if endpoint_exists "$TARGET_ENDPOINT_NAME"; then
      echo "Target endpoint $TARGET_ENDPOINT_NAME already exists. Skipping creation."
    else
      echo "Creating target endpoint: $TARGET_ENDPOINT_NAME"
      aws dms create-endpoint \
        --endpoint-identifier "$TARGET_ENDPOINT_NAME" \
        --endpoint-type target \
        --engine-name "$TGT_ENGINE" \
        --username "$TGT_USER" \
        --password "$TARGET_PASSWORD" \
        --server-name "$TGT_HOST" \
        --port "$TGT_PORT" \
        --database-name "$TGT_DBNAME" \
        ${TGT_SSL_MODE:+--ssl-mode "$TGT_SSL_MODE"} \
        ${TGT_EXTRA:+--extra-connection-attributes "$TGT_EXTRA"} \
        --tags "$TAGS" \
        --no-cli-pager \
        --region "$REGION"
    fi

    # Fetch actual ARNs and validate
    SOURCE_ENDPOINT_ARN=$(get_endpoint_arn "$SOURCE_ENDPOINT_NAME")
    TARGET_ENDPOINT_ARN=$(get_endpoint_arn "$TARGET_ENDPOINT_NAME")

    if [ -z "$SOURCE_ENDPOINT_ARN" ] || [ "$SOURCE_ENDPOINT_ARN" = "null" ]; then
      echo "ERROR: Could not retrieve ARN for source endpoint '$SOURCE_ENDPOINT_NAME'. Skipping task."
      continue
    fi
    if [ -z "$TARGET_ENDPOINT_ARN" ] || [ "$TARGET_ENDPOINT_ARN" = "null" ]; then
      echo "ERROR: Could not retrieve ARN for target endpoint '$TARGET_ENDPOINT_NAME'. Skipping task."
      continue
    fi

    # Create replication task if not exists (not started — start manually)
    # Task type: full-load (migrate existing data only)
    if task_exists "$TASK_NAME"; then
      echo "Replication task $TASK_NAME already exists. Skipping creation."
    else
      echo "Creating replication task: $TASK_NAME"
      aws dms create-replication-task \
        --replication-task-identifier "$TASK_NAME" \
        --source-endpoint-arn "$SOURCE_ENDPOINT_ARN" \
        --target-endpoint-arn "$TARGET_ENDPOINT_ARN" \
        --replication-instance-arn "$REPLICATION_INSTANCE_ARN" \
        --migration-type full-load \
        --table-mappings "file://${TABLE_MAPPINGS_FILE}" \
        --replication-task-settings "file://${TASK_SETTINGS_FILE}" \
        --tags "$TAGS" \
        --no-cli-pager \
        --region "$REGION"
      echo "Task $TASK_NAME created. Start it manually when ready."
    fi

    echo "-----------------------------"
  done
done
