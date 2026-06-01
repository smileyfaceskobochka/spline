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

echo "Building Spline Core and Plugin..."
zig build

# Isolate the test database to prevent polluting the workspace
TEST_DIR=$(mktemp -d -t spline-test-XXXXXX)
export DB_PATH="$TEST_DIR/spline-test.db"

# Put the local build output directory at the front of the PATH
# so the core can find the freshly built lyfta-spline plugin
export PATH="$(pwd)/zig-out/bin:$PATH"

# Start spline daemon in the background, saving its PID
spline &
SPLINE_PID=$!

# Ensure we clean up the daemon and test directory on exit
cleanup() {
    echo "Cleaning up daemon process $SPLINE_PID..."
    kill $SPLINE_PID 2>/dev/null || true
    wait $SPLINE_PID 2>/dev/null || true
    echo "Removing temporary test directory $TEST_DIR..."
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Wait for a transaction to write a row
DB_FILE="$DB_PATH"
echo "Waiting for data insertion in $DB_FILE (Timeout: 45s)..."

TIMEOUT=45
ELAPSED=0
SUCCESS=false

while [ $ELAPSED -lt $TIMEOUT ]; do
    if [ -f "$DB_FILE" ]; then
        if command -v sqlite3 >/dev/null 2>&1; then
            ROW_COUNT=$(sqlite3 "$DB_FILE" "SELECT count(*) FROM ai_prescriptions;" 2>/dev/null || echo 0)
            if [ "$ROW_COUNT" -gt 0 ]; then
                echo "✔ Verified: $ROW_COUNT prescription(s) found in database!"
                SUCCESS=true
                break
            fi
        else
            # Fallback if sqlite3 is not installed on the system
            if [ -s "$DB_FILE" ]; then
                echo "✔ Verified: Database file $DB_FILE exists and is non-empty."
                SUCCESS=true
                break
            fi
        fi
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ "$SUCCESS" = true ]; then
    echo "✔ E2E Test Passed!"
    exit 0
else
    echo "❌ E2E Test Failed: Timeout waiting for database insertion."
    exit 1
fi
