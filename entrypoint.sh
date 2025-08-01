#!/bin/bash

export RUST_BACKTRACE=1

# Set default values for ports
: ${ZO_HTTP_PORT:=5080}
: ${ZO_GRPC_PORT:=5081}

# Function to check if a string is an AWS Secrets Manager ARN
is_secrets_manager_arn() {
    local value="$1"
    [[ "$value" =~ ^arn:aws:secretsmanager: ]]
}

# Function to get secret from AWS Secrets Manager
get_secret_value() {
    local secret_arn="$1"
    local region="${AWS_REGION:-us-east-1}"
    
    echo "DEBUG: Attempting to fetch secret: $secret_arn from region: $region" >&2
    
    # Use AWS CLI to get the secret value
    local result=$(aws secretsmanager get-secret-value \
        --secret-id "$secret_arn" \
        --region "$region" \
        --query 'SecretString' \
        --output text 2>&1)
    
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo "ERROR: AWS CLI failed with exit code $exit_code" >&2
        echo "ERROR: AWS CLI output: $result" >&2
        return 1
    fi
    
    echo "$result"
}

# Function to get JSON value (either from Secrets Manager or direct value)
get_json_value() {
    local input="$1"
    
    if is_secrets_manager_arn "$input"; then
        echo "Fetching secret from AWS Secrets Manager..." >&2
        local secret_value=$(get_secret_value "$input")
        if [ $? -eq 0 ] && [ -n "$secret_value" ]; then
            echo "$secret_value"
        else
            echo "Error: Failed to retrieve secret from Secrets Manager" >&2
            return 1
        fi
    else
        echo "$input"
    fi
}

# Check for required environment variables
required_vars=(
    "ZO_AUTH_JSON"
    "ZO_STORAGE_TYPE"
    "ZO_BUCKET_NAME"
    "ZO_POSTGRES_CONFIG"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: Required environment variable $var is not set."
        exit 1
    fi
done

# Get admin credentials (either from Secrets Manager or direct JSON)
echo "DEBUG: ZO_AUTH_JSON value: $ZO_AUTH_JSON"
ADMIN_SECRET_JSON=$(get_json_value "$ZO_AUTH_JSON")
echo "DEBUG: Retrieved admin secret: $ADMIN_SECRET_JSON"

if [ -z "$ADMIN_SECRET_JSON" ]; then
    echo "Error: Failed to retrieve admin credentials."
    exit 1
fi

# Validate JSON before parsing
if ! echo "$ADMIN_SECRET_JSON" | jq empty 2>/dev/null; then
    echo "Error: Invalid JSON format in admin credentials:"
    echo "$ADMIN_SECRET_JSON"
    exit 1
fi

# Parse JSON and extract user_email and password
ZO_ROOT_USER_EMAIL=$(echo "$ADMIN_SECRET_JSON" | jq -r '.user_email')
ZO_ROOT_USER_PASSWORD=$(echo "$ADMIN_SECRET_JSON" | jq -r '.password')
echo "DEBUG: Extracted email: $ZO_ROOT_USER_EMAIL"
echo "DEBUG: Extracted password: [REDACTED]"

if [ -z "$ZO_ROOT_USER_EMAIL" ] || [ "$ZO_ROOT_USER_EMAIL" == "null" ] || 
   [ -z "$ZO_ROOT_USER_PASSWORD" ] || [ "$ZO_ROOT_USER_PASSWORD" == "null" ]; then
    echo "Error: Failed to extract user_email or password from admin credentials."
    echo "Admin secret JSON: $ADMIN_SECRET_JSON"
    exit 1
fi

# Export the environment variables
export ZO_ROOT_USER_EMAIL
export ZO_ROOT_USER_PASSWORD
export ZO_HTTP_PORT
export ZO_GRPC_PORT

# Export the bucket name
export ZO_S3_BUCKET_NAME="$ZO_BUCKET_NAME"

# Set storage-specific environment variables
if [ "$ZO_STORAGE_TYPE" == "s3" ]; then
    # Use defaults for S3 configuration since storage config is not needed
    export ZO_S3_SERVER_URL="https://s3.amazonaws.com"
    export ZO_S3_REGION_NAME="${ZO_S3_REGION_NAME:-${AWS_REGION:-us-east-1}}"
    export ZO_S3_PROVIDER="s3"
    export ZO_S3_FEATURE_HTTP1_ONLY="true"
    export AWS_EC2_METADATA_DISABLED="false"
    
    # For IAM roles, we don't need to set access keys - AWS SDK will use the IAM role automatically
    echo "Using IAM role for S3 authentication"
    
elif [ "$ZO_STORAGE_TYPE" == "gcs" ]; then
    echo "Error: GCS storage type not supported in AWS App Runner environment."
    exit 1
else
    echo "Error: Invalid ZO_STORAGE_TYPE. Must be 's3'."
    exit 1
fi

# Set default values for metastore configuration
: ${ZO_META_STORE:=postgres}
: ${ZO_META_TRANSACTION_LOCK_TIMEOUT:=600}
: ${ZO_META_TRANSACTION_RETRIES:=3}

export ZO_META_TRANSACTION_LOCK_TIMEOUT
export ZO_META_TRANSACTION_RETRIES

# Parse and set PostgreSQL configuration if metastore is postgres
if [ "$ZO_META_STORE" == "postgres" ]; then
    # Get PostgreSQL credentials (either from Secrets Manager or direct JSON)
    echo "Fetching PostgreSQL credentials..."
    POSTGRES_SECRET_JSON=$(get_json_value "$ZO_POSTGRES_CONFIG")
    if [ -z "$POSTGRES_SECRET_JSON" ]; then
        echo "Error: Failed to retrieve PostgreSQL credentials."
        exit 1
    fi
    
    PG_HOST=$(echo "$POSTGRES_SECRET_JSON" | jq -r '.host')
    PG_PORT=$(echo "$POSTGRES_SECRET_JSON" | jq -r '.port')
    PG_USER=$(echo "$POSTGRES_SECRET_JSON" | jq -r '.username // .user')
    PG_PASSWORD=$(echo "$POSTGRES_SECRET_JSON" | jq -r '.password')
    PG_DATABASE=$(echo "$POSTGRES_SECRET_JSON" | jq -r '.database // "openobserve"')
    
    echo "DEBUG: PG_HOST=$PG_HOST, PG_PORT=$PG_PORT, PG_USER=$PG_USER, PG_DATABASE=$PG_DATABASE"

    if [ -z "$PG_HOST" ] || [ -z "$PG_PORT" ] || [ -z "$PG_USER" ] || [ -z "$PG_PASSWORD" ]; then
        echo "Error: Invalid PostgreSQL configuration. Please check ZO_POSTGRES_CONFIG."
        exit 1
    fi
    
    export ZO_META_POSTGRES_DSN="postgres://${PG_USER}:${PG_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_DATABASE}"
    echo "PostgreSQL configuration set"
fi

# Log the configuration (without sensitive data)
echo "Configuring OpenObserve:"
echo "  HTTP Port: $ZO_HTTP_PORT"
echo "  gRPC Port: $ZO_GRPC_PORT"
echo "  Root User Email: $ZO_ROOT_USER_EMAIL"
echo "  Storage Type: $ZO_STORAGE_TYPE"
echo "  S3 Server URL: $ZO_S3_SERVER_URL"
echo "  S3 Region Name: $ZO_S3_REGION_NAME"
echo "  S3 Bucket Name: $ZO_S3_BUCKET_NAME"
echo "  S3 Provider: $ZO_S3_PROVIDER"
echo "  S3 Feature HTTP1 Only: $ZO_S3_FEATURE_HTTP1_ONLY"
echo "  Meta Store: $ZO_META_STORE"
echo "  Meta Transaction Lock Timeout: $ZO_META_TRANSACTION_LOCK_TIMEOUT"
echo "  Meta Transaction Retries: $ZO_META_TRANSACTION_RETRIES"

# Start Nginx in the background
nginx &

# Execute OpenObserve
exec openobserve