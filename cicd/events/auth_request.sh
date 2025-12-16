#!/usr/bin/env bash
# Event: Auth Request
# Description: Lambda authorizer request event to validate API key authentication
# Expected response: statusCode 200, JSON with Effect "Allow"

set -euo pipefail

echo "--- Auth Request Event Test ---"

# Define the event payload (using double quotes for variable expansion)
EVENT_PAYLOAD="{
  \"type\": \"REQUEST\",
  \"methodArn\": \"arn:aws:execute-api:${API_GATEWAY_REGION}:${AWS_ACCOUNT_ID}:${API_GATEWAY_ID}/${ENVIRONMENT}/GET/wmts/${API_GATEWAY_API_KEY_TEST}20/293624/641561.webp\",
  \"queryStringParameters\": {
    \"api_key\":\"${API_GATEWAY_API_KEY_TEST}\"
  }
}"

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

# Extract the Lambda response (last non-empty line after REPORT, should be JSON)
LAMBDA_RESPONSE=$(echo "$RESPONSE" | grep -A1 "^REPORT" | tail -1)

echo "Lambda response: '$LAMBDA_RESPONSE'"

# Check response is valid JSON
if ! echo "$LAMBDA_RESPONSE" | jq . > /dev/null 2>&1; then
    echo "FAIL: Response is not valid JSON"
    exit 1
fi
echo "✓ Response is valid JSON"

# Check Effect is "Allow"
EFFECT=$(echo "$LAMBDA_RESPONSE" | jq -r '.policyDocument.Statement[0].Effect // empty')
if [[ "$EFFECT" != "Allow" ]]; then
    echo "FAIL: Expected Effect 'Allow', got: '$EFFECT'"
    exit 1
fi
echo "✓ Effect: Allow"

echo ""
echo "Parsed response:"
echo "$LAMBDA_RESPONSE" | jq .

echo ""
echo "--- Auth Request Event Test PASSED ---"
exit 0
