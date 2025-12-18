#!/usr/bin/env bash
# Event: Warmer
# Description: Lambda warmer event to keep the function warm
# Expected response: statusCode 200, body null

set -euo pipefail

echo "--- Warmer Event Test ---"

# Define the event payload
EVENT_PAYLOAD='{
}'

echo "Request payload:"
echo "$EVENT_PAYLOAD" | jq .

# Create temp file for the event
TEMP_EVENT=$(mktemp)
trap "rm -f $TEMP_EVENT" EXIT
echo "$EVENT_PAYLOAD" > "$TEMP_EVENT"

# Invoke Lambda and capture output
echo ""
echo "Invoking Lambda: $LAMBDA"

# Capture response and exit code separately
set +e
RESPONSE=$(sam remote invoke "$LAMBDA" --event-file "$TEMP_EVENT" 2>&1)
INVOKE_EXIT_CODE=$?
set -e

echo ""
echo "Raw output:"
echo "$RESPONSE"
echo ""
echo "Exit code: $INVOKE_EXIT_CODE"

# Validate response
echo ""
echo "--- Validating Response ---"

# Check statusCode 200 (exit code 0 = successful invocation = 200 OK)
if [[ $INVOKE_EXIT_CODE -ne 0 ]]; then
    echo "FAIL: Expected statusCode 200, invocation failed with exit code $INVOKE_EXIT_CODE"
    exit 1
fi
echo "✓ statusCode: 200"

# Extract the Lambda response (last non-empty line after REPORT)
LAMBDA_RESPONSE=$(echo "$RESPONSE" | grep -A1 "^REPORT" | tail -1 | tr -d '[:space:]')

echo "Lambda response: '$LAMBDA_RESPONSE'"

# Check body is null
if [[ "$LAMBDA_RESPONSE" != "null" ]]; then
    echo "FAIL: Expected body to be null, got: '$LAMBDA_RESPONSE'"
    exit 1
fi
echo "✓ body: null"

echo ""
echo "--- Warmer Event Test PASSED ---"
exit 0
