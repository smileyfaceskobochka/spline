#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."

# Load current .env securely
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

# Override interval for rapid testing
export SPLINE_CYCLE_INTERVAL_SEC=5

# Set default Google AI Studio endpoint if none provided
if [ -z "$AI_PROVIDER_URL" ]; then
    export AI_PROVIDER_URL="https://generativelanguage.googleapis.com/v1beta/openai"
fi

if [ -z "$AI_MODEL" ]; then
    export AI_MODEL="gemini-1.5-flash"
fi

echo "Building Spline Core..."
zig build

echo "--- Starting End-to-End Test ---"
echo "AI Endpoint: $AI_PROVIDER_URL"
echo "AI Model:    $AI_MODEL"
echo "Cycle:       ${SPLINE_CYCLE_INTERVAL_SEC}s"
echo "--------------------------------"
echo "Press Ctrl+C to stop after the first cycle completes."

./zig-out/bin/spline
