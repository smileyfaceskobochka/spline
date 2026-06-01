const std = @import("std");

pub const Exercise = struct {
    name: []const u8,
    weight: f64,
    reps: u32,
    rpe: f64,
};

pub const Workout = struct {
    name: []const u8,
    exercises: []Exercise,
};

const RawSet = struct {
    weight: ?[]const u8 = null,
    reps: ?[]const u8 = null,
    rir: ?[]const u8 = null,
};

const RawExercise = struct {
    excercise_name: []const u8,
    sets: []RawSet,
};

const RawWorkout = struct {
    title: []const u8,
    exercises: []RawExercise,
};

const RawResponse = struct {
    status: bool,
    total_pages: u32 = 1,
    current_page: u32 = 1,
    workouts: []RawWorkout,
};

fn parseWeight(s: ?[]const u8) f64 {
    const val = s orelse return 0.0;
    if (std.mem.eql(u8, val, "null") or val.len == 0) return 0.0;
    return std.fmt.parseFloat(f64, val) catch 0.0;
}

fn parseReps(s: ?[]const u8) u32 {
    const val = s orelse return 0;
    if (std.mem.eql(u8, val, "null") or val.len == 0) return 0;
    return std.fmt.parseInt(u32, val, 10) catch 0;
}

fn parseRpe(rir_str: ?[]const u8) f64 {
    const val = rir_str orelse return 0.0;
    if (std.mem.eql(u8, val, "null") or val.len == 0) return 0.0;
    const rir = std.fmt.parseFloat(f64, val) catch return 0.0;
    return 10.0 - rir;
}

/// Fetches a single page of workouts from the Lyfta API.
/// Returns the parsed response which includes pagination metadata.
fn fetchPage(client: *std.http.Client, allocator: std.mem.Allocator, api_key: []const u8, page: u32) !std.json.Parsed(RawResponse) {
    const auth_header_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header_value);

    const url = try std.fmt.allocPrint(allocator, "https://my.lyfta.app/api/v1/workouts?page={d}", .{page});
    defer allocator.free(url);

    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header_value },
        .{ .name = "Accept", .value = "application/json" },
    };

    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    const fetch_res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &headers,
        .response_writer = &response_writer.writer,
    });

    if (fetch_res.status != .ok) {
        std.log.err("Lyfta API returned HTTP {d}", .{@intFromEnum(fetch_res.status)});
        return error.LyftaApiError;
    }

    const response_data = try response_writer.toOwnedSlice();
    defer allocator.free(response_data);

    return try std.json.parseFromSlice(RawResponse, allocator, response_data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Converts a slice of raw workouts into normalized Workout structs.
fn normalizeWorkouts(allocator: std.mem.Allocator, raw_workouts: []const RawWorkout, out: *std.ArrayList(Workout)) !void {
    for (raw_workouts) |w| {
        var exercises_list: std.ArrayList(Exercise) = .empty;
        errdefer {
            for (exercises_list.items) |e| allocator.free(e.name);
            exercises_list.deinit(allocator);
        }

        for (w.exercises) |e| {
            const e_name = try allocator.dupe(u8, e.excercise_name);

            if (e.sets.len == 0) {
                // Exercise with no sets — still record it with zeroed values
                exercises_list.append(allocator, .{
                    .name = e_name,
                    .weight = 0.0,
                    .reps = 0,
                    .rpe = 0.0,
                }) catch |err| {
                    allocator.free(e_name);
                    return err;
                };
            } else {
                // First set uses the allocated name
                exercises_list.append(allocator, .{
                    .name = e_name,
                    .weight = parseWeight(e.sets[0].weight),
                    .reps = parseReps(e.sets[0].reps),
                    .rpe = parseRpe(e.sets[0].rir),
                }) catch |err| {
                    allocator.free(e_name);
                    return err;
                };

                // Subsequent sets get their own copy of the name
                for (e.sets[1..]) |s| {
                    const extra_name = try allocator.dupe(u8, e.excercise_name);
                    exercises_list.append(allocator, .{
                        .name = extra_name,
                        .weight = parseWeight(s.weight),
                        .reps = parseReps(s.reps),
                        .rpe = parseRpe(s.rir),
                    }) catch |err| {
                        allocator.free(extra_name);
                        return err;
                    };
                }
            }
        }

        const title_copy = try allocator.dupe(u8, w.title);
        errdefer allocator.free(title_copy);

        try out.append(allocator, .{
            .name = title_copy,
            .exercises = try exercises_list.toOwnedSlice(allocator),
        });
    }
}

pub fn fetchWorkouts(client: *std.http.Client, allocator: std.mem.Allocator, api_key: []const u8) ![]Workout {
    var workouts_list: std.ArrayList(Workout) = .empty;
    errdefer {
        for (workouts_list.items) |w| {
            for (w.exercises) |e| allocator.free(e.name);
            allocator.free(w.exercises);
            allocator.free(w.name);
        }
        workouts_list.deinit(allocator);
    }

    // Fetch page 1 to discover total_pages
    var page: u32 = 1;
    while (true) {
        const parsed = try fetchPage(client, allocator, api_key, page);
        defer parsed.deinit();

        try normalizeWorkouts(allocator, parsed.value.workouts, &workouts_list);

        std.log.info("Ingested page {d}/{d} ({d} workouts)", .{ page, parsed.value.total_pages, parsed.value.workouts.len });

        if (page >= parsed.value.total_pages) break;
        page += 1;
    }

    return try workouts_list.toOwnedSlice(allocator);
}

pub fn freeWorkouts(allocator: std.mem.Allocator, workouts: []Workout) void {
    for (workouts) |w| {
        for (w.exercises) |e| {
            allocator.free(e.name);
        }
        allocator.free(w.exercises);
        allocator.free(w.name);
    }
    allocator.free(workouts);
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const env_map = init.environ_map;

    const api_key = env_map.get("LYFTA_API_KEY") orelse {
        std.log.err("Missing LYFTA_API_KEY environment variable.", .{});
        return error.MissingLyftaApiKey;
    };

    // Initialize HTTP client
    var client = std.http.Client{
        .allocator = allocator,
        .io = init.io,
    };
    defer client.deinit();

    // Fetch workouts
    const workouts = try fetchWorkouts(&client, allocator, api_key);
    defer freeWorkouts(allocator, workouts);

    // Stringify workouts to an in-memory buffer using the Allocating writer
    var out_buf = std.Io.Writer.Allocating.init(allocator);
    defer out_buf.deinit();
    try std.json.Stringify.value(workouts, .{}, &out_buf.writer);

    const out_slice = try out_buf.toOwnedSlice();
    defer allocator.free(out_slice);

    // Print to stdout using the async I/O framework
    try std.Io.File.stdout().writeStreamingAll(init.io, out_slice);
}

// --- Unit Tests ---

test "lyfta JSON parsing test" {
    const allocator = std.testing.allocator;
    const json_data =
        \\[
        \\  {
        \\    "title": "Push Day A",
        \\    "exercises": [
        \\      {
        \\        "excercise_name": "Bench Press",
        \\        "sets": [
        \\          { "weight": "100.0", "reps": "5", "rir": "1.0" }
        \\        ]
        \\      },
        \\      {
        \\        "excercise_name": "Incline Dumbbell",
        \\        "sets": [
        \\          { "weight": "40.0", "reps": "8", "rir": "1.5" }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\]
    ;

    const parsed = try std.json.parseFromSlice([]RawWorkout, allocator, json_data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualStrings("Push Day A", parsed.value[0].title);
    try std.testing.expectEqual(@as(usize, 2), parsed.value[0].exercises.len);
    try std.testing.expectEqualStrings("Bench Press", parsed.value[0].exercises[0].excercise_name);
    try std.testing.expectEqualStrings("100.0", parsed.value[0].exercises[0].sets[0].weight.?);
}

test "RPE defaults to 0 when RIR is null" {
    try std.testing.expectEqual(@as(f64, 0.0), parseRpe(null));
    try std.testing.expectEqual(@as(f64, 0.0), parseRpe("null"));
    try std.testing.expectEqual(@as(f64, 0.0), parseRpe(""));
    try std.testing.expectEqual(@as(f64, 9.0), parseRpe("1.0"));
    try std.testing.expectEqual(@as(f64, 8.0), parseRpe("2.0"));
}

test "normalizeWorkouts flattens sets into exercises" {
    const allocator = std.testing.allocator;

    const raw_sets = [_]RawSet{
        .{ .weight = "100.0", .reps = "5", .rir = "1.0" },
        .{ .weight = "95.0", .reps = "8", .rir = null },
    };
    const raw_exercises = [_]RawExercise{
        .{ .excercise_name = "Bench Press", .sets = @constCast(&raw_sets) },
    };
    const raw_workouts = [_]RawWorkout{
        .{ .title = "Push Day A", .exercises = @constCast(&raw_exercises) },
    };

    var result: std.ArrayList(Workout) = .empty;
    defer {
        for (result.items) |w| {
            for (w.exercises) |e| allocator.free(e.name);
            allocator.free(w.exercises);
            allocator.free(w.name);
        }
        result.deinit(allocator);
    }

    try normalizeWorkouts(allocator, &raw_workouts, &result);

    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqual(@as(usize, 2), result.items[0].exercises.len);
    try std.testing.expectEqualStrings("Bench Press", result.items[0].exercises[0].name);
    try std.testing.expectEqual(@as(f64, 100.0), result.items[0].exercises[0].weight);
    try std.testing.expectEqual(@as(f64, 9.0), result.items[0].exercises[0].rpe);
    // Second set: null RIR → RPE 0.0
    try std.testing.expectEqualStrings("Bench Press", result.items[0].exercises[1].name);
    try std.testing.expectEqual(@as(f64, 95.0), result.items[0].exercises[1].weight);
    try std.testing.expectEqual(@as(f64, 0.0), result.items[0].exercises[1].rpe);
}
