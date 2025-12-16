#!/usr/bin/env bash
# Lambda Rollback Manager
# Manages Lambda function versions and provides rollback capability using aliases
# 
# Usage:
#   rollback-manager.sh <action> [options]
#
# Actions:
#   update-stable    - Update stable version in Parameter Store and point alias to new version
#   rollback         - Rollback alias to stable version stored in Parameter Store
#   get-stable       - Get current stable version from Parameter Store
#   get-alias        - Get current version the alias points to
#
# Required Environment Variables:
#   LAMBDA              - Lambda function ARN or name
#   LAMBDA_REGION       - AWS region for Lambda operations
#   ENVIRONMENT         - Environment name (dev, test, prod)
#
# Optional Environment Variables:
#   LAMBDA_ALIAS        - Alias name to use (default: "live")

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default alias name
LAMBDA_ALIAS="${LAMBDA_ALIAS:-live}"

# Logging functions - all output to stderr to avoid polluting function return values
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1" >&2
}

# Validate required environment variables
validate_env() {
    local required_vars=("LAMBDA" "LAMBDA_REGION" "ENVIRONMENT")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required environment variable $var is not set"
            exit 1
        fi
    done
}

# Extract Lambda function name from ARN or use directly
get_lambda_function_name() {
    local lambda_input="$LAMBDA"
    local result
    
    if [[ "$lambda_input" == arn:* ]]; then
        # Extract function name from ARN
        # ARN format: arn:aws:lambda:region:account:function:name or arn:aws:lambda:region:account:function:name:qualifier
        result=$(echo "$lambda_input" | sed 's/.*function:\([^:]*\).*/\1/')
    else
        result="$lambda_input"
    fi
    
    echo "$result"
}

# Get the Parameter Store path for stable version
get_stable_version_param_path() {
    local function_name
    function_name=$(get_lambda_function_name)
    echo "/gnextlabs/lambda/${ENVIRONMENT}/${function_name}-STABLE_VERSION"
}

# Get current published Lambda version (latest published, not $LATEST)
get_current_lambda_version() {
    local function_name
    function_name=$(get_lambda_function_name)
    
    log_debug "Getting versions for function: $function_name"
    
    # Get all versions for debugging
    local all_versions
    all_versions=$(aws lambda list-versions-by-function \
        --function-name "$function_name" \
        --region "$LAMBDA_REGION" \
        --query 'Versions[*].Version' \
        --output text 2>&1)
    
    log_debug "All versions returned: $all_versions"
    
    # Get the latest published version (not $LATEST)
    local version
    version=$(echo "$all_versions" | tr '\t' '\n' | grep -v '\$LATEST' | sort -n | tail -1)
    
    log_debug "Latest version selected: $version"
    
    if [[ -z "$version" || "$version" == "None" ]]; then
        log_warn "No published version found, returning 0"
        echo "0"
    else
        echo "$version"
    fi
}

# Get stable version from Parameter Store
get_stable_version() {
    local param_path
    param_path=$(get_stable_version_param_path)
    
    local version
    version=$(aws ssm get-parameter \
        --name "$param_path" \
        --region "$LAMBDA_REGION" \
        --query 'Parameter.Value' \
        --output text 2>/dev/null || echo "")
    
    if [[ -z "$version" || "$version" == "None" ]]; then
        echo ""
    else
        echo "$version"
    fi
}

# Save current version to Parameter Store as stable
save_stable_version() {
    local version="$1"
    local param_path
    param_path=$(get_stable_version_param_path)
    
    log_info "Saving stable version $version to Parameter Store: $param_path"
    
    aws ssm put-parameter \
        --name "$param_path" \
        --value "$version" \
        --type "String" \
        --overwrite \
        --region "$LAMBDA_REGION"
    
    log_info "Stable version saved successfully"
}

# Create or update Lambda alias to point to a specific version
update_alias() {
    local function_name="$1"
    local version="$2"
    local alias_name="$LAMBDA_ALIAS"
    
    log_info "Updating alias '$alias_name' to point to version $version"
    log_debug "Function: $function_name, Version: $version, Alias: $alias_name, Region: $LAMBDA_REGION"
    
    # Skip version verification - version existence is already confirmed via list-versions-by-function
    # If version doesn't exist, the alias update/create will fail with a clear error
    log_info "Proceeding with alias update (version $version confirmed via list-versions)"
    
    # Try to update the alias first
    local update_output
    local update_exit_code
    log_info "Attempting to update alias..."
    
    update_output=$(aws lambda update-alias \
        --function-name "$function_name" \
        --name "$alias_name" \
        --function-version "$version" \
        --region "$LAMBDA_REGION" 2>&1) && update_exit_code=$? || update_exit_code=$?
    
    if [[ $update_exit_code -eq 0 ]]; then
        log_info "Alias '$alias_name' updated successfully"
        log_info "Alias '$alias_name' now points to version $version"
        return 0
    fi
    
    # Check if the error is because alias doesn't exist
    if echo "$update_output" | grep -q "ResourceNotFoundException"; then
        log_info "Alias doesn't exist, creating new alias '$alias_name'..."
        aws lambda create-alias \
            --function-name "$function_name" \
            --name "$alias_name" \
            --function-version "$version" \
            --description "Production alias managed by rollback-manager" \
            --region "$LAMBDA_REGION"
        
        log_info "Alias '$alias_name' created successfully"
        log_info "Alias '$alias_name' now points to version $version"
        return 0
    fi
    
    # Some other error occurred
    log_error "Failed to update alias: $update_output"
    return 1
}

# Get the version that the alias currently points to
get_alias_version() {
    local function_name
    function_name=$(get_lambda_function_name)
    
    local version
    version=$(aws lambda get-alias \
        --function-name "$function_name" \
        --name "$LAMBDA_ALIAS" \
        --region "$LAMBDA_REGION" \
        --query 'FunctionVersion' \
        --output text 2>/dev/null || echo "")
    
    if [[ -z "$version" || "$version" == "None" ]]; then
        echo ""
    else
        echo "$version"
    fi
}

# Update stable version after successful tests
action_update_stable() {
    log_info "=== Updating Stable Version ==="
    
    log_debug "LAMBDA env var: $LAMBDA"
    log_debug "LAMBDA_REGION env var: $LAMBDA_REGION"
    log_debug "ENVIRONMENT env var: $ENVIRONMENT"
    
    local function_name
    function_name=$(get_lambda_function_name)
    log_debug "Extracted function name: $function_name"
    
    # Wait a moment for any eventual consistency
    log_info "Waiting 5 seconds for Lambda version to propagate..."
    sleep 5
    
    local new_version
    new_version=$(get_current_lambda_version)
    
    if [[ "$new_version" == "0" ]]; then
        log_error "No published version found to mark as stable"
        exit 1
    fi
    
    log_info "New version to mark as stable: $new_version"
    
    # Update the alias to point to the new version
    if ! update_alias "$function_name" "$new_version"; then
        log_error "Failed to update alias"
        exit 1
    fi
    
    # Save the new stable version to Parameter Store
    save_stable_version "$new_version"
    
    log_info "============================================"
    log_info "SUCCESS: Stable version updated to: $new_version"
    log_info "Alias '$LAMBDA_ALIAS' now points to version: $new_version"
    log_info "============================================"
}

# Rollback to stable version
action_rollback() {
    log_info "=== Rolling Back to Stable Version ==="
    
    local function_name
    function_name=$(get_lambda_function_name)
    
    local stable_version
    stable_version=$(get_stable_version)
    
    if [[ -z "$stable_version" ]]; then
        log_error "No stable version found in Parameter Store. Cannot rollback."
        log_error "This might be the first deployment. Manual intervention required."
        exit 1
    fi
    
    local current_alias_version
    current_alias_version=$(get_alias_version)
    
    log_info "Current alias '$LAMBDA_ALIAS' points to: ${current_alias_version:-'(not set)'}"
    log_info "Rolling back to stable version: $stable_version"
    
    # Verify the stable version exists
    if ! aws lambda get-function \
        --function-name "${function_name}:${stable_version}" \
        --region "$LAMBDA_REGION" &>/dev/null; then
        log_error "Stable version $stable_version does not exist!"
        exit 1
    fi
    
    # Update the alias to point to the stable version
    update_alias "$function_name" "$stable_version"
    
    log_info "============================================"
    log_info "ROLLBACK COMPLETE"
    log_info "Alias '$LAMBDA_ALIAS' now points to version: $stable_version"
    log_info "============================================"
}

# Get stable version (for display/verification)
action_get_stable() {
    local stable_version
    stable_version=$(get_stable_version)
    
    if [[ -z "$stable_version" ]]; then
        echo "NO_STABLE_VERSION"
    else
        echo "$stable_version"
    fi
}

# Get alias version (for display/verification)
action_get_alias() {
    local alias_version
    alias_version=$(get_alias_version)
    
    if [[ -z "$alias_version" ]]; then
        echo "NO_ALIAS"
    else
        echo "$alias_version"
    fi
}

# Main entry point
main() {
    local action="${1:-}"
    
    if [[ -z "$action" ]]; then
        log_error "Usage: $0 <action> [options]"
        log_error "Actions: update-stable, rollback, get-stable, get-alias"
        exit 1
    fi
    
    validate_env
    
    log_info "Lambda Function: $(get_lambda_function_name)"
    log_info "Environment: $ENVIRONMENT"
    log_info "Alias: $LAMBDA_ALIAS"
    log_info "Region: $LAMBDA_REGION"
    
    case "$action" in
        update-stable)
            action_update_stable
            ;;
        rollback)
            action_rollback
            ;;
        get-stable)
            action_get_stable
            ;;
        get-alias)
            action_get_alias
            ;;
        *)
            log_error "Unknown action: $action"
            log_error "Valid actions: update-stable, rollback, get-stable, get-alias"
            exit 1
            ;;
    esac
}

main "$@"
