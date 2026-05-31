# Spline Core: Architecture & Design

## 1. System Objective

**Spline Core** is a lightweight, zero-dependency, configuration-driven background daemon written in systems-level Zig. Its goal is to act as a centralized data aggregator for human performance telemetry. It orchestrates decentralized data ingestion modules (`*-spline`), serializes multi-layered data arrays into an ultra-compact Token Oriented Object Notation (TOON) string using a native C99 compression engine (`ctoon`), and drives LLM inference to generate holistic, recovery-aware progressive overload training targets.

---

## 2. Core Engineering Philosophy

* **Idiomatic Systems Safety:** The daemon infrastructure relies strictly on Zig-native libraries and standard library primitives (`std.posix`, `std.process`). C-interoperability is explicitly restricted to the high-performance compression boundary, avoiding the pitfalls of raw pointer arithmetic and unsafe standard C libraries for OS-level tasks.
* **Explicit Memory Isolation:** Transient, high-churn memory overhead (network buffers, raw JSON strings, parsed environment maps) is strictly constrained to per-cycle Zig Arena Allocators. Memory is wiped completely clear at the end of every execution loop.
* **Zero-Allocation FFI Handshake:** The native C99 execution boundary (`ctoon`) relies entirely on caller-owned memory. The core allocates fixed buffers and passes raw pointers (`.ptr`) across the ABI, ensuring `malloc` and `free` are never invoked inside the serialization layer.
* **Decoupled Architecture:** The system uses a strict host-and-plugin pattern. The **Spline Core** engine handles memory management, scheduling, SQLite transactions, and inference routing. Individual modules (beginning with `lyfta-spline`) are responsible solely for targeted API extraction and native Zig struct normalization.

---

## 3. Technology Stack

| Component        | Technology        | Purpose                                                                                                                    |
| ---------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **Orchestrator** | Zig               | HTTP networking, memory arenas, system daemon loop, and environment map parsing.                                           |
| **Compression**  | C99 (`ctoon`)     | `stb`-style single-header TOON encoder to minimize LLM context limits.                                                     |
| **Storage**      | Zig-Native SQLite | Embedded database utilizing a type-safe Zig wrapper around SQLite for `try`/`catch` integration and struct-to-row mapping. |
| **Inference**    | OpenAI REST API   | Standardized communication layer for both local and remote AI models.                                                      |
| **DevOps**       | Systemd           | Linux background service management, crash recovery, and logging.                                                          |

---

## 4. Configuration-Driven Environment

The application behavior, model routing, and AI personality are strictly controlled by `.env` variables mapped into memory via Zig's `std.process.getEnvMap()`.

| Variable                    | Expected Value | Example                       | Purpose                                                              |
| --------------------------- | -------------- | ----------------------------- | -------------------------------------------------------------------- |
| `SPLINE_CYCLE_INTERVAL_SEC` | Integer        | `14400`                       | Loop sleep timer (e.g., 14400s = 4 hours).                           |
| `LYFTA_API_KEY`             | String         | `ey...`                       | Authentication for the `lyfta-spline` ingestion module.              |
| `AI_PROVIDER_URL`           | URI String     | `http://localhost:11434/v1`   | Explicitly defines the inference endpoint (e.g., local Ollama).      |
| `AI_MODEL`                  | String         | `gemma4:e4b`                  | Defines the exact target model identifier for the JSON request body. |
| `AI_TRAINER_PROMPT`         | String         | `"You are an elite coach..."` | System role assignment controlling the coaching persona.             |

---

## 5. The First Module: `lyfta-spline`

The training telemetry layer is handled by the `lyfta-spline` data adapter module.

* **Scope:** It maps raw, nested JSON payloads down to explicit, statically typed Zig data structures. Unknown upstream API adjustments are mitigated by forcing the parser rules to ignore undeclared keys.
* **Output Matrix:** The module outputs a flat, chronological sequence of workout profiles, exercise arrays, and localized performance blocks (Weight, Reps, RPE).

### Master TOON String Construction Blueprint

When **Spline Core** serializes the data streams, the `lyfta-spline` data block maps directly to the primary workout node layout:

```text
# --- MODULE: lyfta-spline ---
workout:Push Day A
exercises[2]{name,weight,reps,rpe}:
  Bench Press,100,5,9
  Incline Dumbbell,40,8,8.5

```

---

## 6. Execution Lifecycle Loop

### Phase 1: Modular Ingestion

The core wakes up and invokes an isolated Arena Allocator. The core hits the registration table and executes the `lyfta-spline` extraction sequence. The module collects the network string, maps it to memory structs, and yields control back to the core.

### Phase 2: Serialization Matrix

The core iterates over the data structures, assembling them into contiguous text buffers in the Arena. It performs a direct pointer handshake across the FFI boundary, dropping data right into `ctoon_encode()` to compile a clean, token-efficient string.

### Phase 3: Inference Orator

The core maps the parameters outlined by `AI_PROVIDER_URL`, packaging `AI_TRAINER_PROMPT` as the `system` configuration and the compressed TOON structure as the `user` context. A type-safe JSON payload is assembled and dispatched to the endpoint via a standard HTTP POST.

### Phase 4: Storage & Reset

The core receives the AI prescription payload and executes a strongly-typed SQLite `INSERT` transaction via the Zig-native database driver. The core then sweeps the active cycle Arena out of memory, reducing the background daemon footprint back to baseline, and enters its designated sleep window.

---

## 7. Storage Schema

External applications interact with `spline.db` exclusively by querying this schema in a read-only capacity.

```sql
CREATE TABLE IF NOT EXISTS ai_prescriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    split_name TEXT NOT NULL,
    toon_context TEXT NOT NULL,         -- Contains the full multi-layer TOON snapshot
    ai_recommendation TEXT NOT NULL,    -- The generated workout target
    status TEXT DEFAULT 'pending_execution'
);

```

---

## 8. Lifecycle & DevOps Management

The daemon is designed as continuous, autonomous infrastructure.

* **Systemd Integration:** Deployed as a background service (`spline-core.service`) with `Restart=on-failure` to recover from unexpected API drops or Ollama timeouts.
* **Native POSIX Signals:** Intercepts shutdown requests using Zig's native `std.posix.sigaction` directed at `SIGINT` and `SIGTERM`, eliminating legacy C-header vulnerabilities.
* **Atomic Loop Handlers:** An atomic boolean (`keep_running`) manages the main execution loop. If a termination signal is received during an active network fetch or database write, the daemon suppresses the exit, completes the atomic operation, commits the SQLite transaction, and safely exits.
