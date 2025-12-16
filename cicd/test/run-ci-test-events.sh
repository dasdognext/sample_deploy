#!/usr/bin/env bash
# Script to execute Lambda test event scripts from cicd/events folder
# Each event script handles its own invocation and response validation
# Designed to run in AWS CodeBuild (Amazon Linux 2/2023)

set -euo pipefail  # Safer bash options

# Validate required environment variables
: "${LAMBDA:?Error: LAMBDA environment variable is not set}"

# Determine the script's directory and the events folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENTS_DIR="${SCRIPT_DIR}/../events"

# Export LAMBDA so event scripts can use it
export LAMBDA
export EVENTS_DIR

echo "Lambda ARN: $LAMBDA"
echo "Events directory: $EVENTS_DIR"
echo ""

# Ensure sam CLI is installed
if ! command -v sam >/dev/null 2>&1; then
    echo "Error: 'sam' CLI not found in PATH"
    exit 1
fi

# Check if events directory exists
if [[ ! -d "$EVENTS_DIR" ]]; then
    echo "Error: Events directory not found: $EVENTS_DIR"
    exit 1
fi

# Find all shell scripts in the events directory
mapfile -t EVENT_SCRIPTS < <(find "$EVENTS_DIR" -maxdepth 1 -name "*.sh" -type f | sort)

# Check if any event scripts exist
if [[ ${#EVENT_SCRIPTS[@]} -eq 0 ]]; then
    echo "No event scripts (.sh) found in $EVENTS_DIR"
    exit 0
fi

echo "Found ${#EVENT_SCRIPTS[@]} event script(s) to execute"
echo ""

# Track results
PASSED=0
FAILED=0

# Execute each event script
for EVENT_SCRIPT in "${EVENT_SCRIPTS[@]}"; do
    EVENT_NAME=$(basename "$EVENT_SCRIPT" .sh)
    
    echo "=========================================="
    echo "Executing event: $EVENT_NAME"
    echo "Script: $EVENT_SCRIPT"
    echo "=========================================="
    
    # Make sure the script is executable
    chmod +x "$EVENT_SCRIPT"
    
    # Execute the event script
    if "$EVENT_SCRIPT"; then
        echo "✓ PASSED: $EVENT_NAME"
        PASSED=$((PASSED + 1))
    else
        echo "✗ FAILED: $EVENT_NAME"
        FAILED=$((FAILED + 1))
    fi
    
    echo ""
done

echo "=========================================="
echo "RESULTS SUMMARY"
echo "=========================================="
echo "Total: $((PASSED + FAILED))"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo "Some event tests failed!"
    exit 1
fi

echo "All event tests passed successfully."
