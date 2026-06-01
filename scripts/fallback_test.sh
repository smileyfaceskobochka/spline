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

# Isolate the test database
TEST_DIR=$(mktemp -d -t spline-fallback-test-XXXXXX)
export DB_PATH="$TEST_DIR/spline-test.db"
DB_FILE="$DB_PATH"

# Put local build output directory at front of PATH
export PATH="$(pwd)/zig-out/bin:$PATH"

# Start spline daemon in the background
spline &
SPLINE_PID=$!

cleanup() {
    echo "Cleaning up daemon process $SPLINE_PID..."
    kill $SPLINE_PID 2>/dev/null || true
    wait $SPLINE_PID 2>/dev/null || true
    
    # Restore plugin binary if renamed
    if [ -f "zig-out/bin/lyfta-spline-temp" ]; then
        mv "zig-out/bin/lyfta-spline-temp" "zig-out/bin/lyfta-spline"
    fi
    
    echo "Removing temporary test directory $TEST_DIR..."
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

echo "Waiting for initial ingestion and prescription..."
TIMEOUT=30
ELAPSED=0
SUCCESS_PHASE1=false

while [ $ELAPSED -lt $TIMEOUT ]; do
    if [ -f "$DB_FILE" ]; then
        ROW_COUNT=$(sqlite3 "$DB_FILE" "SELECT count(*) FROM ai_prescriptions;" 2>/dev/null || echo 0)
        WORKOUT_COUNT=$(sqlite3 "$DB_FILE" "SELECT count(*) FROM ingested_workouts;" 2>/dev/null || echo 0)
        if [ "$ROW_COUNT" -gt 0 ] && [ "$WORKOUT_COUNT" -gt 0 ]; then
            echo "✔ Initial ingestion succeeded: $WORKOUT_COUNT workouts cached, $ROW_COUNT prescription created."
            SUCCESS_PHASE1=true
            break
        fi
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ "$SUCCESS_PHASE1" = false ]; then
    echo "❌ Phase 1 Failed: Timeout waiting for initial ingestion."
    exit 1
fi

# Simulate API/plugin outage by renaming the plugin binary
echo "Simulating API outage by renaming plugin..."
mv "zig-out/bin/lyfta-spline" "zig-out/bin/lyfta-spline-temp"

# Clear the prescription so the daemon runs inference again
echo "Clearing prescription table to trigger new inference..."
sqlite3 "$DB_FILE" "DELETE FROM ai_prescriptions;"

echo "Waiting for fallback cycle to complete..."
ELAPSED=0
SUCCESS_PHASE2=false

while [ $ELAPSED -lt $TIMEOUT ]; do
    ROW_COUNT=$(sqlite3 "$DB_FILE" "SELECT count(*) FROM ai_prescriptions;" 2>/dev/null || echo 0)
    if [ "$ROW_COUNT" -gt 0 ]; then
        echo "✔ Fallback verification succeeded! Found $ROW_COUNT prescription(s) generated during API outage."
        SUCCESS_PHASE2=true
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ "$SUCCESS_PHASE2" = true ]; then
    echo "✔ API Fallback E2E Test Passed!"
    exit 0
else
    echo "❌ API Fallback E2E Test Failed: Daemon did not generate prescription from cache."
    exit 1
fi
