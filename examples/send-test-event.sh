#!/usr/bin/env bash
# Send a sample Jenkins failure to the forwarder, signed with SigV4, without Jenkins.
#
# Usage:
#   ./examples/send-test-event.sh <ForwarderEndpoint> [region] [payload.json]
#
# Your current AWS credentials must belong to the JenkinsPrincipalArn you deployed
# with (e.g. assume that role first), otherwise Lambda returns 403.
set -euo pipefail

ENDPOINT="${1:?usage: $0 <ForwarderEndpoint> [region] [payload.json]}"
REGION="${2:-us-east-1}"
PAYLOAD="${3:-$(dirname "$0")/sample-payload.json}"

if ! CREDS=$(aws configure export-credentials --format env); then
  echo "No AWS credentials found; sign in or export credentials for the Jenkins principal first." >&2
  exit 1
fi
eval "$CREDS"; unset CREDS

umask 077
CURL_CFG=$(mktemp)
trap 'rm -f "$CURL_CFG"' EXIT
printf 'user = "%s:%s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" > "$CURL_CFG"
if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
  printf 'header = "x-amz-security-token: %s"\n' "$AWS_SESSION_TOKEN" >> "$CURL_CFG"
fi

curl -sS -K "$CURL_CFG" \
  --aws-sigv4 "aws:amz:${REGION}:lambda" \
  -H 'Content-Type: application/json' \
  --data-binary @"$PAYLOAD" \
  -w '\nHTTP %{http_code}\n' \
  "$ENDPOINT"
