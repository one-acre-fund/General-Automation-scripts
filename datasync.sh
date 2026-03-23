#!/bin/bash

# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
AWS_REGION="eu-west-1"
DATASYNC_AGENT_ARN=""
IAM_ROLE_ARN=""
SECRETS_MANAGER_SECRET_NAME=""

# ─────────────────────────────────────────────
# MAP: Azure Blob Storage Account → S3 Bucket Name
#
# Just provide bucket names — ARN built automatically
#
# Secrets Manager JSON should have key = storage account name:
# {
#     "nasafloodarchive":  "sv=2023-xx-xx&ss=b...",
#     "nasafloodarchive2": "sv=2023-xx-xx&ss=b...",
#     "nasafloodarchive3": "sv=2023-xx-xx&ss=b..."
# }
# ─────────────────────────────────────────────
declare -A BLOB_TO_S3_MAP=(
    ["nasafloodarchive"]="nasafloodarchive-aws-mig"
    ["fc76834212b5741ad989712"]="fc76834212b5741ad989712-aws-mig"
)

echo "========================================"
echo "DEBUG: AWS_REGION             : $AWS_REGION"
echo "DEBUG: SECRETS_MANAGER_SECRET : $SECRETS_MANAGER_SECRET_NAME"
echo "DEBUG: DATASYNC_AGENT_ARN     : $DATASYNC_AGENT_ARN"
echo "DEBUG: IAM_ROLE_ARN           : $IAM_ROLE_ARN"
echo "DEBUG: BLOB TO S3 MAPPING     :"
for ACCOUNT in "${!BLOB_TO_S3_MAP[@]}"; do
    echo "       $ACCOUNT → ${BLOB_TO_S3_MAP[$ACCOUNT]}"
done
echo "========================================"

# ─────────────────────────────────────────────
# Fetch FULL secret JSON once (contains all SAS tokens)
# No new secret is created — only reads existing
# ─────────────────────────────────────────────
echo ""
echo "Fetching all SAS tokens from Secrets Manager..."

SECRET_JSON=$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$SECRETS_MANAGER_SECRET_NAME" \
    --query SecretString \
    --output text 2>&1)

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to fetch secret from Secrets Manager."
    echo "Details: $SECRET_JSON"
    exit 1
fi

echo "DEBUG: Secret fetched successfully."
echo "DEBUG: Available keys in secret: $(echo "$SECRET_JSON" | jq -r 'keys[]')"

# ─────────────────────────────────────────────
# Helper: Get existing Azure Blob location ARN
# ─────────────────────────────────────────────
function get_existing_azure_location {
    local CONTAINER_URL="$1"

    echo "DEBUG: Searching for existing Azure location: $CONTAINER_URL" >&2

    ALL_LOCATIONS=$(aws datasync list-locations \
        --region "$AWS_REGION" \
        --output json 2>&1)

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to list DataSync locations." >&2
        echo ""
        return 1
    fi

    AZURE_ARNS=$(echo "$ALL_LOCATIONS" | jq -r \
        '.Locations[] | select(.LocationUri | startswith("azure-blob://")) | .LocationArn')

    if [ -z "$AZURE_ARNS" ]; then
        echo "DEBUG: No existing Azure Blob locations found." >&2
        echo ""
        return 1
    fi

    while IFS= read -r LOC_ARN; do
        [ -z "$LOC_ARN" ] && continue

        LOC_DETAILS=$(aws datasync describe-location-azure-blob \
            --region "$AWS_REGION" \
            --location-arn "$LOC_ARN" \
            --output json 2>&1)

        if [ $? -ne 0 ]; then
            echo "DEBUG: Failed to describe $LOC_ARN, skipping." >&2
            continue
        fi

        EXISTING_URL=$(echo "$LOC_DETAILS" | jq -r '.ContainerUrl')

        echo "DEBUG: Comparing: existing='$EXISTING_URL' | target='$CONTAINER_URL'" >&2

        if [[ "$EXISTING_URL" == "$CONTAINER_URL" ]]; then
            echo "DEBUG: ✅ Match found! Reusing: $LOC_ARN" >&2
            echo "$LOC_ARN"
            return 0
        fi

    done <<< "$AZURE_ARNS"

    echo "DEBUG: No matching Azure location found for: $CONTAINER_URL" >&2
    echo ""
    return 1
}

# ─────────────────────────────────────────────
# Helper: Get existing S3 location ARN
# ─────────────────────────────────────────────
function get_existing_s3_location {
    local SUBDIRECTORY="$1"
    local BUCKET_NAME="$2"

    # AWS DataSync always stores S3 URI with trailing slash
    local EXPECTED_URI="s3://${BUCKET_NAME}${SUBDIRECTORY}/"

    echo "DEBUG: Searching for existing S3 location: $EXPECTED_URI" >&2

    ALL_LOCATIONS=$(aws datasync list-locations \
        --region "$AWS_REGION" \
        --output json 2>&1)

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to list DataSync locations." >&2
        echo ""
        return 1
    fi

    S3_ARNS=$(echo "$ALL_LOCATIONS" | jq -r \
        '.Locations[] | select(.LocationUri | startswith("s3://")) | .LocationArn')

    if [ -z "$S3_ARNS" ]; then
        echo "DEBUG: No existing S3 locations found." >&2
        echo ""
        return 1
    fi

    while IFS= read -r LOC_ARN; do
        [ -z "$LOC_ARN" ] && continue

        LOC_URI=$(aws datasync describe-location-s3 \
            --region "$AWS_REGION" \
            --location-arn "$LOC_ARN" \
            --query "LocationUri" \
            --output text 2>&1)

        echo "DEBUG: Comparing: existing='$LOC_URI' | expected='$EXPECTED_URI'" >&2

        if [[ "$LOC_URI" == "$EXPECTED_URI" ]]; then
            echo "DEBUG: ✅ Match found! Reusing: $LOC_ARN" >&2
            echo "$LOC_ARN"
            return 0
        fi

    done <<< "$S3_ARNS"

    echo "DEBUG: No matching S3 location found for: $EXPECTED_URI" >&2
    echo ""
    return 1
}

# ─────────────────────────────────────────────
# Helper: Get existing DataSync task by name
# ─────────────────────────────────────────────
function get_existing_task {
    local TASK_NAME="$1"

    echo "DEBUG: Searching for existing task: $TASK_NAME" >&2

    ALL_TASKS=$(aws datasync list-tasks \
        --region "$AWS_REGION" \
        --output json 2>&1)

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to list DataSync tasks." >&2
        echo ""
        return 1
    fi

    TASK_ARN=$(echo "$ALL_TASKS" | jq -r \
        --arg NAME "$TASK_NAME" \
        '.Tasks[] | select(.Name == $NAME) | .TaskArn')

    if [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "null" ]; then
        echo "DEBUG: ✅ Found existing task: $TASK_ARN" >&2
        echo "$TASK_ARN"
        return 0
    fi

    echo "DEBUG: No existing task found: $TASK_NAME" >&2
    echo ""
    return 1
}

# ─────────────────────────────────────────────
# MAIN LOOP: Iterate over each blob → s3 mapping
# ─────────────────────────────────────────────
for AZURE_STORAGE_ACCOUNT in "${!BLOB_TO_S3_MAP[@]}"; do

    # Get bucket name from map
    S3_BUCKET_NAME="${BLOB_TO_S3_MAP[$AZURE_STORAGE_ACCOUNT]}"

    # Build ARN automatically from bucket name
    S3_BUCKET_ARN="arn:aws:s3:::${S3_BUCKET_NAME}"

    echo ""
    echo "###################################################"
    echo "# Storage Account : $AZURE_STORAGE_ACCOUNT"
    echo "# S3 Bucket Name  : $S3_BUCKET_NAME"
    echo "# S3 Bucket ARN   : $S3_BUCKET_ARN"
    echo "###################################################"

    # ─────────────────────────────────────────
    # Get SAS token for THIS storage account
    # Key in secret = storage account name
    # ─────────────────────────────────────────
    SAS_TOKEN=$(echo "$SECRET_JSON" | jq -r --arg KEY "$AZURE_STORAGE_ACCOUNT" '.[$KEY]')

    if [ -z "$SAS_TOKEN" ] || [ "$SAS_TOKEN" == "null" ]; then
        echo "ERROR: SAS token key '$AZURE_STORAGE_ACCOUNT' not found in Secrets Manager."
        echo "DEBUG: Available keys: $(echo "$SECRET_JSON" | jq -r 'keys[]')"
        echo "Skipping storage account: $AZURE_STORAGE_ACCOUNT"
        continue
    fi

    echo "DEBUG: ✅ SAS token retrieved for: $AZURE_STORAGE_ACCOUNT"

    # ─────────────────────────────────────────
    # List all containers in this storage account
    # ─────────────────────────────────────────
    echo ""
    echo "Listing containers in: $AZURE_STORAGE_ACCOUNT"

    CONTAINERS=$(az storage container list \
        --account-name "$AZURE_STORAGE_ACCOUNT" \
        --sas-token "$SAS_TOKEN" \
        --query '[].name' \
        --output tsv 2>&1)

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to list containers for: $AZURE_STORAGE_ACCOUNT"
        echo "Details: $CONTAINERS"
        echo "Skipping storage account: $AZURE_STORAGE_ACCOUNT"
        continue
    fi

    echo "Found containers: $CONTAINERS"

    # ─────────────────────────────────────────
    # Process each container
    # ─────────────────────────────────────────
    for CONTAINER in $CONTAINERS; do
        echo ""
        echo "========================================"
        echo "Storage Account : $AZURE_STORAGE_ACCOUNT"
        echo "Container       : $CONTAINER"
        echo "S3 Bucket       : $S3_BUCKET_NAME"
        echo "========================================"

        AZURE_CONTAINER_URL="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}"
        SUBDIRECTORY="/${CONTAINER}"
        TASK_NAME="migrate-${AZURE_STORAGE_ACCOUNT}-${CONTAINER}"

        echo "DEBUG: Azure URL  : $AZURE_CONTAINER_URL"
        echo "DEBUG: S3 Subdir  : $SUBDIRECTORY"
        echo "DEBUG: Task Name  : $TASK_NAME"

        # ─────────────────────────────────────
        # 3. Get or Create Azure source location
        # ─────────────────────────────────────
        SOURCE_LOCATION_ARN=$(get_existing_azure_location "$AZURE_CONTAINER_URL")

        if [ -n "$SOURCE_LOCATION_ARN" ]; then
            echo "✅ Reusing existing Azure source location: $SOURCE_LOCATION_ARN"
        else
            echo "Creating new Azure source location..."
            SOURCE_LOCATION_ARN=$(aws datasync create-location-azure-blob \
                --region "$AWS_REGION" \
                --container-url "$AZURE_CONTAINER_URL" \
                --authentication-type SAS \
                --sas-configuration Token="$SAS_TOKEN" \
                --agent-arns "$DATASYNC_AGENT_ARN" \
                --query LocationArn \
                --output text 2>&1)

            if [ $? -ne 0 ]; then
                echo "ERROR: Failed to create Azure source location for $CONTAINER."
                echo "Details: $SOURCE_LOCATION_ARN"
                continue
            fi
            echo "✅ Created Azure source location: $SOURCE_LOCATION_ARN"
        fi

        # ─────────────────────────────────────
        # 4. Get or Create S3 destination location
        # Pass bucket name — ARN used internally
        # ─────────────────────────────────────
        DEST_LOCATION_ARN=$(get_existing_s3_location "$SUBDIRECTORY" "$S3_BUCKET_NAME")

        if [ -n "$DEST_LOCATION_ARN" ]; then
            echo "✅ Reusing existing S3 destination location: $DEST_LOCATION_ARN"
        else
            echo "Creating new S3 destination location..."
            DEST_LOCATION_ARN=$(aws datasync create-location-s3 \
                --region "$AWS_REGION" \
                --s3-bucket-arn "$S3_BUCKET_ARN" \
                --subdirectory "$SUBDIRECTORY" \
                --s3-config BucketAccessRoleArn="$IAM_ROLE_ARN" \
                --query LocationArn \
                --output text 2>&1)

            if [ $? -ne 0 ]; then
                echo "ERROR: Failed to create S3 destination location for $CONTAINER."
                echo "Details: $DEST_LOCATION_ARN"
                continue
            fi
            echo "✅ Created S3 destination location: $DEST_LOCATION_ARN"
        fi

        # ─────────────────────────────────────
        # 5. Get or Create DataSync task
        # ─────────────────────────────────────
        TASK_ARN=$(get_existing_task "$TASK_NAME")

        if [ -n "$TASK_ARN" ]; then
            echo "✅ Reusing existing DataSync task: $TASK_ARN"
        else
            echo "Creating new DataSync task: $TASK_NAME"
            TASK_ARN=$(aws datasync create-task \
                --region "$AWS_REGION" \
                --source-location-arn "$SOURCE_LOCATION_ARN" \
                --destination-location-arn "$DEST_LOCATION_ARN" \
                --name "$TASK_NAME" \
                --options ObjectTags=NONE \
                --query TaskArn \
                --output text 2>&1)

            if [ $? -ne 0 ]; then
                echo "ERROR: Failed to create DataSync task for $CONTAINER."
                echo "Details: $TASK_ARN"
                continue
            fi
            echo "✅ Created DataSync task: $TASK_ARN"
        fi

        # ─────────────────────────────────────
        # 6. Check if task execution already running
        # ─────────────────────────────────────
        TASK_EXEC_ARN=""

        RUNNING_EXEC=$(aws datasync list-task-executions \
            --region "$AWS_REGION" \
            --task-arn "$TASK_ARN" \
            --output json 2>&1 | jq -r '.TaskExecutions[0].TaskExecutionArn // empty')

        if [ -n "$RUNNING_EXEC" ]; then
            EXEC_STATUS=$(aws datasync describe-task-execution \
                --region "$AWS_REGION" \
                --task-execution-arn "$RUNNING_EXEC" \
                --query "Status" \
                --output text 2>&1)

            echo "DEBUG: Last execution: $RUNNING_EXEC | Status: $EXEC_STATUS"

            if [[ "$EXEC_STATUS" == "LAUNCHING" || \
                  "$EXEC_STATUS" == "PREPARING" || \
                  "$EXEC_STATUS" == "TRANSFERRING" || \
                  "$EXEC_STATUS" == "VERIFYING" ]]; then
                echo "⏳ Task already running ($EXEC_STATUS). Monitoring existing execution."
                TASK_EXEC_ARN="$RUNNING_EXEC"
            else
                echo "Last execution was '$EXEC_STATUS'. Starting new execution."
            fi
        fi

        if [ -z "$TASK_EXEC_ARN" ]; then
            TASK_EXEC_ARN=$(aws datasync start-task-execution \
                --region "$AWS_REGION" \
                --task-arn "$TASK_ARN" \
                --query TaskExecutionArn \
                --output text 2>&1)

            if [ $? -ne 0 ]; then
                echo "ERROR: Failed to start task execution for $CONTAINER."
                echo "Details: $TASK_EXEC_ARN"
                continue
            fi
            echo "✅ Started new task execution: $TASK_EXEC_ARN"
        fi

        # ─────────────────────────────────────
        # 7. Monitor task completion
        # ─────────────────────────────────────
        echo "Monitoring: $TASK_EXEC_ARN"
        while true; do
            STATUS=$(aws datasync describe-task-execution \
                --region "$AWS_REGION" \
                --task-execution-arn "$TASK_EXEC_ARN" \
                --query Status \
                --output text 2>&1)

            if [ $? -ne 0 ]; then
                echo "ERROR: Failed to describe task execution."
                echo "Details: $STATUS"
                break
            fi

            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Account: $AZURE_STORAGE_ACCOUNT | Container: $CONTAINER | Status: $STATUS"

            if [[ "$STATUS" == "SUCCESS" ]]; then
                echo "✅ Migration SUCCESS — Account: $AZURE_STORAGE_ACCOUNT | Container: $CONTAINER"
                break
            elif [[ "$STATUS" == "ERROR" ]]; then
                echo "❌ Migration ERROR — Account: $AZURE_STORAGE_ACCOUNT | Container: $CONTAINER"
                break
            else
                sleep 30
            fi
        done

    done
    # end container loop

done
# end storage account loop

echo ""
echo "========================================"
echo "All storage accounts processed."
echo "========================================"
