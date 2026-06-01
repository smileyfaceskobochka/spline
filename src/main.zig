const std = @import("std");
const Io = std.Io;

const spline = @import("spline");

// Force compilation of FFI allocator bridge exports
comptime {
    _ = spline.spline_c_alloc;
    _ = spline.spline_c_calloc;
    _ = spline.spline_c_realloc;
    _ = spline.spline_c_free;
}

var keep_running = std.atomic.Value(bool).init(true);

const Exercise = struct {
    name: []const u8,
    weight: f64,
    reps: u32,
    rpe: f64,
    notes: ?[]const u8 = null,
};

const Workout = struct {
    name: []const u8,
    exercises: []Exercise,
};

fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    keep_running.store(false, .unordered);
}

fn dupStringToC(s: []const u8) ![*]u8 {
    const ptr = spline.spline_c_alloc(s.len + 1) orelse return error.OutOfMemory;
    const bytes = @as([*]u8, @ptrCast(ptr));
    @memcpy(bytes[0..s.len], s);
    bytes[s.len] = 0;
    return bytes;
}

fn queryInference(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    provider_url: []const u8,
    api_key: ?[]const u8,
    model: []const u8,
    prompt: []const u8,
    toon_data: []const u8,
) ![]const u8 {
    const ChatMessage = struct {
        role: []const u8,
        content: []const u8,
    };
    const ChatPayload = struct {
        model: []const u8,
        messages: []const ChatMessage,
    };

    const messages = [_]ChatMessage{
        .{ .role = "system", .content = prompt },
        .{ .role = "user", .content = toon_data },
    };
    const payload = ChatPayload{
        .model = model,
        .messages = &messages,
    };

    var payload_writer = std.Io.Writer.Allocating.init(allocator);
    defer payload_writer.deinit();
    try std.json.Stringify.value(payload, .{}, &payload_writer.writer);
    const payload_string = try payload_writer.toOwnedSlice();
    defer allocator.free(payload_string);

    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    const completions_url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{provider_url});
    defer allocator.free(completions_url);

    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |h| allocator.free(h);

    var headers_buf: [2]std.http.Header = undefined;
    var num_headers: usize = 0;

    headers_buf[num_headers] = .{ .name = "Content-Type", .value = "application/json" };
    num_headers += 1;

    if (api_key) |k| {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{k});
        headers_buf[num_headers] = .{ .name = "Authorization", .value = auth_header.? };
        num_headers += 1;
    }

    const fetch_res = try client.fetch(.{
        .location = .{ .url = completions_url },
        .method = .POST,
        .payload = payload_string,
        .extra_headers = headers_buf[0..num_headers],
        .response_writer = &response_writer.writer,
    });

    if (fetch_res.status != .ok) {
        std.log.err("AI Provider returned HTTP {d}", .{@intFromEnum(fetch_res.status)});
        return error.AiProviderError;
    }

    const response_data = try response_writer.toOwnedSlice();
    defer allocator.free(response_data);

    const ResponseMessage = struct {
        content: []const u8,
    };
    const ResponseChoice = struct {
        message: ResponseMessage,
    };
    const ChatResponse = struct {
        choices: []const ResponseChoice,
    };

    const parsed_response = try std.json.parseFromSlice(ChatResponse, allocator, response_data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed_response.deinit();

    if (parsed_response.value.choices.len == 0) {
        return error.NoChoicesReturned;
    }

    return try allocator.dupe(u8, parsed_response.value.choices[0].message.content);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Initialize persistent DebugAllocator for long-lived components
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    // Register signal handlers for graceful shutdown
    var act = std.posix.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    std.log.info("Spline Core background daemon started.", .{});

    // 1. Initial configuration mapping from .env file or environment
    const env_map = init.environ_map;

    // Parse loop interval strictly (fail-fast)
    const cycle_interval_raw = env_map.get("SPLINE_CYCLE_INTERVAL_SEC") orelse {
        std.log.err("Missing mandatory SPLINE_CYCLE_INTERVAL_SEC environment variable.", .{});
        return error.MissingCycleInterval;
    };
    const cycle_interval_sec = std.fmt.parseInt(u64, cycle_interval_raw, 10) catch |err| {
        std.log.err("Failed to parse SPLINE_CYCLE_INTERVAL_SEC: {s}", .{@errorName(err)});
        return err;
    };

    _ = env_map.get("LYFTA_API_KEY") orelse {
        std.log.err("Missing mandatory LYFTA_API_KEY environment variable.", .{});
        return error.MissingLyftaApiKey;
    };

    const ai_provider_url = env_map.get("AI_PROVIDER_URL") orelse {
        std.log.err("Missing mandatory AI_PROVIDER_URL environment variable.", .{});
        return error.MissingAiProviderUrl;
    };
    const ai_provider_api_key = env_map.get("AI_PROVIDER_API_KEY");

    const ai_model = env_map.get("AI_MODEL") orelse {
        std.log.err("Missing mandatory AI_MODEL environment variable.", .{});
        return error.MissingAiModel;
    };

    const ai_trainer_prompt = env_map.get("AI_TRAINER_PROMPT") orelse {
        std.log.err("Missing mandatory AI_TRAINER_PROMPT environment variable.", .{});
        return error.MissingAiTrainerPrompt;
    };

    const workout_num_raw = env_map.get("LYFTA_WORKOUT_NUM") orelse {
        std.log.err("Missing mandatory LYFTA_WORKOUT_NUM environment variable.", .{});
        return error.MissingLyftaWorkoutNum;
    };
    const workout_num = std.fmt.parseInt(usize, workout_num_raw, 10) catch |err| {
        std.log.err("Failed to parse LYFTA_WORKOUT_NUM: {s}", .{@errorName(err)});
        return err;
    };

    const user_context = env_map.get("USER_CONTEXT");
    const db_path_raw = env_map.get("DB_PATH") orelse "spline.db";

    var db_path_buf: [1024]u8 = undefined;
    const db_path_z = std.fmt.bufPrintZ(&db_path_buf, "{s}", .{db_path_raw}) catch {
        std.log.err("DB_PATH configuration is too long (limit is 1023 characters).", .{});
        return error.DbPathTooLong;
    };

    // Initialize single persistent HTTP client
    var client = std.http.Client{
        .allocator = gpa_allocator,
        .io = io,
    };
    defer client.deinit();

    // 2. Open SQLite database and initialize tables
    var db = try spline.SqliteDb.open(db_path_z);
    defer db.close();

    try db.execute("CREATE TABLE IF NOT EXISTS ai_prescriptions (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP, split_name TEXT NOT NULL, toon_context TEXT NOT NULL, ai_recommendation TEXT NOT NULL, status TEXT DEFAULT 'pending_execution');");
    try db.execute("CREATE TABLE IF NOT EXISTS ingested_workouts (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP, title TEXT NOT NULL, toon_data TEXT UNIQUE NOT NULL);");

    // Main execution loop
    while (keep_running.load(.unordered)) {
        std.log.info("Starting new data ingestion and inference cycle...", .{});

        // Initialize transient cycle Arena Allocator
        var cycle_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer cycle_arena.deinit();
        const arena = cycle_arena.allocator();

        // Run this loop iteration
        runCycle(&client, arena, io, workout_num, ai_provider_url, ai_provider_api_key, ai_model, ai_trainer_prompt, user_context, &db) catch |err| {
            std.log.err("Error during iteration cycle: {s}", .{@errorName(err)});
        };

        // Sleep until next cycle interval, waking up early if keep_running goes false
        const start_ts = std.Io.Clock.Timestamp.now(io, .awake);
        while (keep_running.load(.unordered)) {
            const elapsed = start_ts.untilNow(io).raw.toMilliseconds();
            if (elapsed >= @as(i64, @intCast(cycle_interval_sec)) * 1000) break;
            const d = std.Io.Clock.Duration{
                .raw = std.Io.Duration.fromMilliseconds(100),
                .clock = .awake,
            };
            d.sleep(io) catch |err| {
                if (err == error.Canceled) break;
                return err;
            };
        }
    }

    std.log.info("Spline Core background daemon stopped cleanly.", .{});
}

fn serializeWorkoutToToon(arena: std.mem.Allocator, w: Workout) ![]const u8 {
    // Set thread-local allocator before calling C FFI
    spline.current_allocator = arena;
    defer spline.current_allocator = null;

    const w_obj = spline.c.toon_value_object() orelse return error.OutOfMemory;
    defer spline.c.toon_value_free(w_obj);

    const workout_name_slot = spline.c.toon_obj_set(w_obj, "name") orelse return error.OutOfMemory;
    workout_name_slot.*.type = spline.c.TOON_STRING;
    workout_name_slot.*.unnamed_0.str_val = try dupStringToC(w.name);

    const exercises_slot = spline.c.toon_obj_set(w_obj, "exercises") orelse return error.OutOfMemory;
    exercises_slot.*.type = spline.c.TOON_ARRAY;

    for (w.exercises) |e| {
        const ex_obj = spline.c.toon_array_push(exercises_slot) orelse return error.OutOfMemory;
        ex_obj.*.type = spline.c.TOON_OBJECT;

        const name_slot = spline.c.toon_obj_set(ex_obj, "name") orelse return error.OutOfMemory;
        name_slot.*.type = spline.c.TOON_STRING;
        name_slot.*.unnamed_0.str_val = try dupStringToC(e.name);

        const weight_slot = spline.c.toon_obj_set(ex_obj, "weight") orelse return error.OutOfMemory;
        weight_slot.*.type = spline.c.TOON_NUMBER;
        weight_slot.*.num_val = e.weight;

        const reps_slot = spline.c.toon_obj_set(ex_obj, "reps") orelse return error.OutOfMemory;
        reps_slot.*.type = spline.c.TOON_NUMBER;
        reps_slot.*.num_val = @floatFromInt(e.reps);

        const rpe_slot = spline.c.toon_obj_set(ex_obj, "rpe") orelse return error.OutOfMemory;
        rpe_slot.*.type = spline.c.TOON_NUMBER;
        rpe_slot.*.num_val = e.rpe;

        const notes_slot = spline.c.toon_obj_set(ex_obj, "notes") orelse return error.OutOfMemory;
        notes_slot.*.type = spline.c.TOON_STRING;
        notes_slot.*.unnamed_0.str_val = try dupStringToC(e.notes orelse "");
    }

    var opts = spline.c.toon_encoder_opts{
        .indent_size = 2,
        .delimiter = ',',
        .key_folding = 0,
        .flatten_depth = 1,
    };
    const toon_out = spline.c.toon_encode(w_obj, &opts) orelse return error.SerializationFailed;
    defer spline.spline_c_free(toon_out);

    return try arena.dupe(u8, std.mem.span(toon_out));
}

fn formatWorkoutToonAsArrayElement(arena: std.mem.Allocator, raw_toon: []const u8) ![]const u8 {
    var out_list = std.Io.Writer.Allocating.init(arena);
    errdefer out_list.deinit();

    var line_it = std.mem.splitScalar(u8, raw_toon, '\n');
    var is_first = true;
    while (line_it.next()) |line| {
        if (line.len == 0) continue;

        if (is_first) {
            try out_list.writer.print("  - {s}\n", .{line});
            is_first = false;
        } else {
            try out_list.writer.print("  {s}\n", .{line});
        }
    }
    return try out_list.toOwnedSlice();
}

fn runTelemetryPlugin(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const argv = [_][]const u8{"lyfta-spline"};
    const run_result = std.process.run(arena, io, .{
        .argv = &argv,
    }) catch |err| {
        std.log.err("Failed to execute telemetry plugin: {s}", .{@errorName(err)});
        return err;
    };

    if (run_result.stderr.len > 0) {
        std.log.info("Plugin stderr output:\n{s}", .{run_result.stderr});
    }

    switch (run_result.term) {
        .exited => |code| {
            if (code != 0) {
                std.log.err("Plugin 'lyfta-spline' exited with code {d}", .{code});
                return error.PluginFailed;
            }
        },
        else => {
            std.log.err("Plugin 'lyfta-spline' terminated abnormally", .{});
            return error.PluginTerminated;
        },
    }

    return run_result.stdout;
}

fn runCycle(
    client: *std.http.Client,
    arena: std.mem.Allocator,
    io: Io,
    workout_num: usize,
    ai_provider_url: []const u8,
    ai_provider_api_key: ?[]const u8,
    ai_model: []const u8,
    ai_trainer_prompt: []const u8,
    user_context: ?[]const u8,
    db: *spline.SqliteDb,
) !void {
    // Phase 1: Run external telemetry plugin with retry
    var fetch_attempts: u32 = 0;
    var plugin_stdout: ?[]const u8 = null;
    while (fetch_attempts < 3) : (fetch_attempts += 1) {
        if (runTelemetryPlugin(arena, io)) |out| {
            plugin_stdout = out;
            break;
        } else |err| {
            std.log.err("Failed to run telemetry plugin (attempt {d}/3): {s}", .{ fetch_attempts + 1, @errorName(err) });
            if (fetch_attempts == 2) {
                std.log.warn("Telemetry plugin failed completely. Falling back to SQLite cached workouts.", .{});
            } else {
                const backoff_ms = @as(i64, 2000) * (@as(i64, 1) << @as(u5, @intCast(fetch_attempts)));
                std.log.info("Sleeping {d}ms before retry...", .{backoff_ms});
                const d = std.Io.Clock.Duration{
                    .raw = std.Io.Duration.fromMilliseconds(backoff_ms),
                    .clock = .awake,
                };
                d.sleep(io) catch {};
            }
        }
    }

    // If the API succeeded, process and save new workouts
    if (plugin_stdout) |stdout_data| {
        const parsed_workouts = std.json.parseFromSlice([]Workout, arena, stdout_data, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("Failed to parse plugin JSON output: {s}", .{@errorName(err)});
            return err;
        };
        const workouts = parsed_workouts.value;

        var new_workouts_count: usize = 0;
        for (workouts) |w| {
            const w_toon = try serializeWorkoutToToon(arena, w);
            const formatted_toon = try formatWorkoutToonAsArrayElement(arena, w_toon);

            // Attempt to insert. If changes() is greater than 0, it was a new workout.
            try db.db.exec("INSERT OR IGNORE INTO ingested_workouts (title, toon_data) VALUES (?1, ?2)", .{ w.name, formatted_toon });
            if (db.db.changes() > 0) {
                new_workouts_count += 1;
            }
        }
        if (new_workouts_count > 0) {
            std.log.info("Ingested {d} new workouts this cycle.", .{new_workouts_count});
        } else {
            std.log.info("No new workouts found in this cycle.", .{});
        }
    }

    // Phase 2: Retrieve recent workouts from the database cache
    var db_workouts: std.ArrayList([]const u8) = .empty;
    defer db_workouts.deinit(arena);

    // Query the last N workouts, ordered chronologically (oldest first)
    var rows = try db.db.rows("SELECT title, toon_data FROM (SELECT id, title, toon_data FROM ingested_workouts ORDER BY id DESC LIMIT ?1) ORDER BY id ASC", .{workout_num});
    defer rows.deinit();

    while (rows.next()) |r| {
        const toon_data = r.get([]const u8, 1);
        try db_workouts.append(arena, try arena.dupe(u8, toon_data));
    }

    if (db_workouts.items.len == 0) {
        std.log.info("No workouts found in database cache. Skipping cycle.", .{});
        return;
    }

    // Phase 3: Construct master TOON context
    var toon_builder = std.Io.Writer.Allocating.init(arena);
    defer toon_builder.deinit();

    try toon_builder.writer.print("workouts[{d}]:\n", .{db_workouts.items.len});
    for (db_workouts.items) |w_toon| {
        try toon_builder.writer.print("{s}", .{w_toon});
    }

    const toon_string = try toon_builder.toOwnedSlice();
    std.log.info("TOON context built for 'Next Session':\n{s}", .{toon_string});

    // Deduplication Check
    if (try db.prescriptionExists("Next Session", toon_string)) {
        std.log.info("Prescription for 'Next Session' with matching context already exists. Skipping.", .{});
        return;
    }

    // Phase 4: Inference Orator (query LLM) with retry
    std.log.info("Dispatching context to AI inference provider...", .{});

    var final_prompt: []const u8 = ai_trainer_prompt;
    if (user_context) |ctx| {
        final_prompt = try std.fmt.allocPrint(arena, "{s}\n\nUSER EXPLICIT RULES & SPLIT CONTEXT:\n{s}", .{
            ai_trainer_prompt,
            ctx,
        });
    }

    var ai_recommendation: []const u8 = undefined;
    var query_attempts: u32 = 0;
    while (query_attempts < 3) : (query_attempts += 1) {
        if (queryInference(client, arena, ai_provider_url, ai_provider_api_key, ai_model, final_prompt, toon_string)) |resp| {
            ai_recommendation = resp;
            break;
        } else |err| {
            std.log.err("Failed to query AI provider (attempt {d}/3): {s}", .{ query_attempts + 1, @errorName(err) });
            if (query_attempts == 2) return err;
            const backoff_ms = @as(i64, 2000) * (@as(i64, 1) << @as(u5, @intCast(query_attempts)));
            std.log.info("Sleeping {d}ms before AI retry...", .{backoff_ms});
            const d = std.Io.Clock.Duration{
                .raw = std.Io.Duration.fromMilliseconds(backoff_ms),
                .clock = .awake,
            };
            d.sleep(io) catch {};
        }
    }
    defer arena.free(ai_recommendation);

    std.log.info("Received AI prescription for 'Next Session':\n{s}", .{ai_recommendation});

    // Phase 5: Storage
    try db.insertPrescription("Next Session", toon_string, ai_recommendation);
    std.log.info("Saved prescription to SQLite database.", .{});
}
