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
    allocator: std.mem.Allocator,
    io: Io,
    provider_url: []const u8,
    api_key: ?[]const u8,
    model: []const u8,
    prompt: []const u8,
    toon_data: []const u8,
) ![]const u8 {
    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.connection_pool.deinit(io);

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
    
    // Parse loop interval
    const cycle_interval_sec: u64 = if (env_map.get("SPLINE_CYCLE_INTERVAL_SEC")) |val|
        std.fmt.parseInt(u64, val, 10) catch 14400
    else
        14400;

    const lyfta_api_key = env_map.get("LYFTA_API_KEY") orelse {
        std.log.err("Missing LYFTA_API_KEY environment variable.", .{});
        return error.MissingLyftaApiKey;
    };

    const ai_provider_url = env_map.get("AI_PROVIDER_URL") orelse "http://localhost:11434/v1";
    const ai_provider_api_key = env_map.get("AI_PROVIDER_API_KEY");
    const ai_model = env_map.get("AI_MODEL") orelse "gemma4:e4b";
    const ai_trainer_prompt = env_map.get("AI_TRAINER_PROMPT") orelse "You are an elite coach. Generate recovery-aware progressive overload training targets.";

    const workout_num: usize = if (env_map.get("LYFTA_WORKOUT_NUM")) |val|
        std.fmt.parseInt(usize, val, 10) catch 5
    else
        5;

    const user_context = env_map.get("USER_CONTEXT");
    const db_path_raw = env_map.get("DB_PATH") orelse "spline.db";

    var db_path_buf: [1024]u8 = undefined;
    const db_path_z = std.fmt.bufPrintZ(&db_path_buf, "{s}", .{db_path_raw}) catch "spline.db";

    // 2. Open SQLite database and initialize tables
    var db = try spline.SqliteDb.open(db_path_z);
    defer db.close();

    try db.execute("CREATE TABLE IF NOT EXISTS ai_prescriptions (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP, split_name TEXT NOT NULL, toon_context TEXT NOT NULL, ai_recommendation TEXT NOT NULL, status TEXT DEFAULT 'pending_execution');");

    // Main execution loop
    while (keep_running.load(.unordered)) {
        std.log.info("Starting new data ingestion and inference cycle...", .{});

        // Initialize transient cycle Arena Allocator
        var cycle_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer cycle_arena.deinit();
        const arena = cycle_arena.allocator();

        // Run this loop iteration
        runCycle(arena, io, lyfta_api_key, workout_num, ai_provider_url, ai_provider_api_key, ai_model, ai_trainer_prompt, user_context, &db) catch |err| {
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

fn runCycle(
    arena: std.mem.Allocator,
    io: Io,
    api_key: []const u8,
    workout_num: usize,
    ai_provider_url: []const u8,
    ai_provider_api_key: ?[]const u8,
    ai_model: []const u8,
    ai_trainer_prompt: []const u8,
    user_context: ?[]const u8,
    db: *spline.SqliteDb,
) !void {
    // Phase 1: Modular Ingestion (fetch workouts) with retry
    var fetch_attempts: u32 = 0;
    var workouts: []spline.lyfta.Workout = undefined;
    while (fetch_attempts < 3) : (fetch_attempts += 1) {
        if (spline.lyfta.fetchWorkouts(arena, io, api_key)) |w| {
            workouts = w;
            break;
        } else |err| {
            std.log.err("Failed to fetch workouts (attempt {d}/3): {s}", .{ fetch_attempts + 1, @errorName(err) });
            if (fetch_attempts == 2) return err;
            const backoff_ms = @as(i64, 2000) * (@as(i64, 1) << @as(u5, @intCast(fetch_attempts)));
            std.log.info("Sleeping {d}ms before retry...", .{backoff_ms});
            const d = std.Io.Clock.Duration{
                .raw = std.Io.Duration.fromMilliseconds(backoff_ms),
                .clock = .awake,
            };
            d.sleep(io) catch {};
        }
    }
    // No need to defer freeWorkouts — arena bulk-deallocates on cycle_arena.deinit()

    if (workouts.len == 0) {
        std.log.info("No workouts ingested this cycle.", .{});
        return;
    }

    // Set thread-local allocator before calling ctoon C FFI methods
    spline.current_allocator = arena;
    defer spline.current_allocator = null;

    // Phase 2: Serialization Matrix (TOON format)
    const root_obj = spline.c.toon_value_object() orelse return error.OutOfMemory;
    defer spline.c.toon_value_free(root_obj);

    const workouts_slot = spline.c.toon_obj_set(root_obj, "workouts") orelse return error.OutOfMemory;
    workouts_slot.*.type = spline.c.TOON_ARRAY;

    const slice_len = @min(workouts.len, workout_num);
    const recent_workouts = workouts[0..slice_len];

    for (recent_workouts) |w| {
        const w_obj = spline.c.toon_array_push(workouts_slot) orelse return error.OutOfMemory;
        w_obj.*.type = spline.c.TOON_OBJECT;

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
        }
    }

    var opts = spline.c.toon_encoder_opts{
        .indent_size = 2,
        .delimiter = ',',
        .key_folding = 0,
        .flatten_depth = 1,
    };
    const toon_out = spline.c.toon_encode(root_obj, &opts) orelse return error.SerializationFailed;
    defer spline.spline_c_free(toon_out);

    const toon_string = std.mem.span(toon_out);
    std.log.info("TOON context built for 'Next Session':\n{s}", .{toon_string});

    // Deduplication Check
    if (try db.prescriptionExists("Next Session", toon_string)) {
        std.log.info("Prescription for 'Next Session' with matching context already exists. Skipping.", .{});
        return;
    }

    // Phase 3: Inference Orator (query LLM) with retry
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
        if (queryInference(arena, io, ai_provider_url, ai_provider_api_key, ai_model, final_prompt, toon_string)) |resp| {
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

    // Phase 4: Storage
    try db.insertPrescription("Next Session", toon_string, ai_recommendation);
    std.log.info("Saved prescription to SQLite database.", .{});
}
