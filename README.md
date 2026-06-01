<div align="center">
  <img src="banner.png" alt="Spline Banner" width="100%">
</div>

## Overview

Spline Core is an autonomous background daemon that pulls your training history from the [Lyfta API](https://lyfta.app), analyzes your volume, and queries a Large Language Model (LLM) to prescribe a workout for your next session.

It leverages the [TOON (Token Oriented Object Notation)](https://toonformat.dev) format via `ctoon` to deeply compress nested workout structures (Sets, Weights, RPEs, Exercises) before sending them to the LLM. This drastically reduces token costs and prevents the AI from hallucinating fake exercises or unrealistic weight jumps.

## Installation & Usage

Spline Core uses a decoupled architecture where telemetry is gathered by standalone plugin executables (e.g. `lyfta-spline`) invoked by the main orchestrator (`spline`). Both binaries must be compiled and present in the system `PATH`.

### 1. Configuration

Create a `.env` file in the root of the directory:

```env
# Daemon cycle interval in seconds (e.g., 86400 = 24 hours)
SPLINE_CYCLE_INTERVAL_SEC=86400

# SQLite Database Location (defaults to spline.db in working dir)
DB_PATH=spline.db

# Lyfta API configuration
LYFTA_API_KEY=your_lyfta_api_key_here
LYFTA_WORKOUT_NUM=5

# LLM Configuration (Default: Groq)
AI_PROVIDER_URL=https://api.groq.com/openai/v1
AI_PROVIDER_API_KEY=your_groq_key_here
AI_MODEL=llama-3.1-8b-instant

# Optional: Persistent rules for the AI
USER_CONTEXT="Currently running a Push/Pull/Legs split. Avoid heavy deadlifts."
```

### 2. Run the Daemon (Docker Compose)

Boot the daemon in the background using Docker Compose. The container will automatically compile both the orchestrator and plugin binaries, and load the `.env` configuration file:

```bash
docker compose up -d
```

### 3. View Logs

You can monitor the daemon executing the telemetry plugin, querying the LLM, and saving prescriptions:

```bash
docker compose logs -f
```
## Built With

- **[Zig](https://ziglang.org/)** - The core language for the daemon.
- **[ctoon](https://github.com/smileyfaceskobochka/ctoon)** - C library for TOON serialization/deserialization.
- **[zqlite](https://github.com/karlseguin/zqlite.zig)** - Thin Zig wrapper for SQLite.
- **[Groq](https://groq.com/)** - Ultra-fast LLM inference API.
