#!/bin/bash

CONFIG_FILE="config.json"

ACCOUNT_ID="952409747009"
REGION="eu-west-1"
REPLICATION_INSTANCE_ARN="arn:aws:dms:eu-west-1:952409747009:rep:WQ57NKVXF5GWJDXOET6KBSFLMM"

TABLE_MAPPINGS_FILE="table-mappings.json"
TASK_SETTINGS_FILE="task-settings.json"

endpoint_exists() {
  local endpoint_id="$1"
  aws dms describe-endpoints --filters "Name=endpoint-id,Values=$endpoint_id" --region "$REGION" | grep -q "\"EndpointIdentifier\": \"$endpoint_id\""
}

get_endpoint_arn() {
  local endpoint_id="$1"
  aws dms describe-endpoints --filters "Name=endpoint-id,Values=$endpoint_id" --region "$REGION" \
    | jq -r '.Endpoints[0].EndpointArn'
}

jq -c '.servers[]' "$CONFIG_FILE" | while read -r server; do
  SERVER_NAME=$(echo "$server" | jq -r '.name')
  echo "Processing server: $SERVER_NAME"
  echo "$server" | jq -c '.databases[]' | while read -r db; do
    DB_NAME=$(echo "$db" | jq -r '.name')
    PASSWORD=$(echo "$db" | jq -r '.password')

    # Source endpoint details
    SRC_HOST=$(echo "$db" | jq -r '.source_endpoint.host')
    SRC_PORT=$(echo "$db" | jq -r '.source_endpoint.port')
    SRC_USER=$(echo "$db" | jq -r '.source_endpoint.username')
    SRC_ENGINE=$(echo "$db" | jq -r '.source_endpoint.engine_name // "sqlserver"')
    SRC_DBNAME=$(echo "$db" | jq -r '.source_endpoint.database_name // empty')
    SRC_SSL_MODE=$(echo "$db" | jq -r '.source_endpoint.ssl_mode // empty')
    SOURCE_ENDPOINT_NAME="${SERVER_NAME}-${DB_NAME}-source"

    # Target endpoint details
    TGT_HOST=$(echo "$db" | jq -r '.target_endpoint.host')
    TGT_PORT=$(echo "$db" | jq -r '.target_endpoint.port')
    TGT_USER=$(echo "$db" | jq -r '.target_endpoint.username')
    TGT_ENGINE=$(echo "$db" | jq -r '.target_endpoint.engine_name // "sqlserver"')
    TGT_DBNAME=$(echo "$db" | jq -r '.target_endpoint.database_name // empty')
    TGT_SSL_MODE=$(echo "$db" | jq -r '.target_endpoint.ssl_mode // empty')
    TARGET_ENDPOINT_NAME="${SERVER_NAME}-${DB_NAME}-target"

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
        --password "$PASSWORD" \
        --server-name "$SRC_HOST" \
        --port "$SRC_PORT" \
        --database-name "$SRC_DBNAME" \
        ${SRC_SSL_MODE:+--ssl-mode "$SRC_SSL_MODE"} \
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
        --password "$PASSWORD" \
        --server-name "$TGT_HOST" \
        --port "$TGT_PORT" \
        --database-name "$TGT_DBNAME" \
        ${TGT_SSL_MODE:+--ssl-mode "$TGT_SSL_MODE"} \
        --region "$REGION"
    fi

    # Fetch actual ARNs
    SOURCE_ENDPOINT_ARN=$(get_endpoint_arn "$SOURCE_ENDPOINT_NAME")
    TARGET_ENDPOINT_ARN=$(get_endpoint_arn "$TARGET_ENDPOINT_NAME")

    # Task: source to target
    TASK_NAME="task-${SERVER_NAME}-${DB_NAME}-source-to-target"
    echo "Creating replication task: $TASK_NAME"
    aws dms create-replication-task \
      --replication-task-identifier "$TASK_NAME" \
      --source-endpoint-arn "$SOURCE_ENDPOINT_ARN" \
      --target-endpoint-arn "$TARGET_ENDPOINT_ARN" \
      --replication-instance-arn "$REPLICATION_INSTANCE_ARN" \
      --migration-type full-load \
      --table-mappings "file://${TABLE_MAPPINGS_FILE}" \
      --replication-task-settings "file://${TASK_SETTINGS_FILE}" \
      --region "$REGION"

    echo "-----------------------------"
  done
done