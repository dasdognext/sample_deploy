#!/usr/bin/env bash
# Script to execute Lambda test events that match a specific prefix
# Works in Windows Git Bash using sam.cmd

set -euo pipefail  # Safer bash options

# ====== CONFIGURATION ======

# Required: Lambda ARN or function name
LAMBDA="arn:aws:lambda:us-east-1:856380239196:function:auth_lambda"

# Optional: prefix for test event names (defaults to "ci-")
EVENT_PREFIX="${EVENT_PREFIX:-ci-}"

# Path to SAM CLI (Windows + Git Bash)
# You can override this by exporting SAM_BIN before running the script
SAM_BIN="${SAM_BIN:-/c/Program Files/Amazon/AWSSAMCLI/bin/sam.cmd}"

# ====== CHECKS ======

if [[ ! -f "$SAM_BIN" ]]; then
    echo "Error: SAM CLI not found at:"
    echo "  $SAM_BIN"
    echo ""
    echo "If SAM is installed elsewhere, set SAM_BIN, e.g.:"
    echo "  export SAM_BIN=\"/c/Some/Other/Path/sam.cmd\""
    exit 1
fi

echo "Using SAM CLI at: $SAM_BIN"
"$SAM_BIN" --version || true
echo ""

echo "Lambda: $LAMBDA"
echo "Event prefix filter: $EVENT_PREFIX"
echo ""

# ====== LIST TEST EVENTS ======

echo "Fetching shareable test events for Lambda function..."

TEST_EVENTS_OUTPUT="$("$SAM_BIN" remote test-event list "$LAMBDA" 2>/dev/null || true)"

if [[ -z "$TEST_EVENTS_OUTPUT" ]]; then
    echo "No test events found or unable to list events."
    exit 0
fi

# Extract event names that start with the prefix, ignore empty lines
mapfile -t EVENT_NAMES < <(
    printf '%s\n' "$TEST_EVENTS_OUTPUT" \
    | awk -v p="$EVENT_PREFIX" 'NF > 0 && index($0, p) == 1 { print $0 }'
)

if [[ ${#EVENT_NAMES[@]} -eq 0 ]]; then
    echo "No test events found matching prefix '$EVENT_PREFIX'"
    exit 0
fi

echo "Found ${#EVENT_NAMES[@]} test event(s) matching prefix '$EVENT_PREFIX'"
printf '  - %s\n' "${EVENT_NAMES[@]}"
echo ""

# ====== EXECUTE EACH EVENT ======

for EVENT_NAME in "${EVENT_NAMES[@]}"; do
    echo "=========================================="
    echo "Executing test event: $EVENT_NAME"
    echo "=========================================="

    if "$SAM_BIN" remote invoke "$LAMBDA" --test-event-name "$EVENT_NAME"; then
        echo "✓ Successfully executed: $EVENT_NAME"
    else
        echo "✗ Failed to execute: $EVENT_NAME"
        exit 1
    fi

    echo ""
done

echo "All matching test events have been executed successfully."
