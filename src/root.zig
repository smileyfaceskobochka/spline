const std = @import("std");

pub const c = @cImport({
    @cInclude("toon.h");
});

const zqlite = @import("zqlite");

// --- Custom Memory Allocator Bridge for ctoon FFI ---

pub threadlocal var current_allocator: ?std.mem.Allocator = null;

const Header = struct {
    size: usize,
    _pad: usize = 0,
};

pub export fn spline_c_alloc(size: usize) callconv(.c) ?*anyopaque {
    const allocator = current_allocator orelse return null;
    const total_size = size + @sizeOf(Header);
    // Allocate memory with 16-byte alignment to satisfy max_align_t
    const bytes = allocator.allocWithOptions(u8, total_size, .of(std.c.max_align_t), null) catch return null;
    const header = @as(*Header, @ptrCast(bytes.ptr));
    header.size = total_size;
    return bytes.ptr + @sizeOf(Header);
}

pub export fn spline_c_calloc(num: usize, size: usize) callconv(.c) ?*anyopaque {
    const total_bytes = num * size;
    const ptr = spline_c_alloc(total_bytes) orelse return null;
    @memset(@as([*]u8, @ptrCast(ptr))[0..total_bytes], 0);
    return ptr;
}

pub export fn spline_c_free(ptr: ?*anyopaque) callconv(.c) void {
    const raw_ptr = ptr orelse return;
    const allocator = current_allocator orelse return;
    const header_ptr = @as(*Header, @ptrCast(@alignCast(@as([*]u8, @ptrCast(raw_ptr)) - @sizeOf(Header))));
    const total_size = header_ptr.size;
    const slice = @as([*]align(16) u8, @ptrCast(@alignCast(header_ptr)))[0..total_size];
    allocator.free(slice);
}

pub export fn spline_c_realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const raw_ptr = ptr orelse return spline_c_alloc(size);
    if (size == 0) {
        spline_c_free(raw_ptr);
        return null;
    }
    const allocator = current_allocator orelse return null;
    const header_ptr = @as(*Header, @ptrCast(@alignCast(@as([*]u8, @ptrCast(raw_ptr)) - @sizeOf(Header))));
    const old_total_size = header_ptr.size;
    const old_slice = @as([*]align(16) u8, @ptrCast(@alignCast(header_ptr)))[0..old_total_size];

    const new_total_size = size + @sizeOf(Header);
    const new_bytes = allocator.realloc(old_slice, new_total_size) catch return null;
    const new_header = @as(*Header, @ptrCast(new_bytes.ptr));
    new_header.size = new_total_size;
    return new_bytes.ptr + @sizeOf(Header);
}

comptime {
    _ = spline_c_alloc;
    _ = spline_c_calloc;
    _ = spline_c_realloc;
    _ = spline_c_free;
}

// --- Type-safe SQLite DB Wrapper ---

pub const SqliteDb = struct {
    db: zqlite.Conn,

    pub fn open(path: [:0]const u8) !SqliteDb {
        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite;
        const conn = try zqlite.open(path, flags);
        errdefer conn.close();

        // Enforce a busy timeout (5000ms) to queue concurrent operations instead of throwing SQLITE_BUSY
        try conn.exec("PRAGMA busy_timeout = 5000;", .{});

        return SqliteDb{ .db = conn };
    }

    pub fn close(self: *SqliteDb) void {
        self.db.close();
    }

    pub fn execute(self: *SqliteDb, comptime sql: []const u8) !void {
        try self.db.exec(sql, .{});
    }

    pub fn insertPrescription(self: *SqliteDb, split_name: []const u8, toon_context: []const u8, ai_recommendation: []const u8) !void {
        try self.db.exec("INSERT INTO ai_prescriptions (split_name, toon_context, ai_recommendation) VALUES (?1, ?2, ?3)", .{ split_name, toon_context, ai_recommendation });
    }

    pub fn prescriptionExists(self: *SqliteDb, split_name: []const u8, toon_context: []const u8) !bool {
        const row = try self.db.row("SELECT 1 FROM ai_prescriptions WHERE split_name = ?1 AND toon_context = ?2 LIMIT 1", .{ split_name, toon_context });
        if (row) |r| {
            r.deinit();
            return true;
        }
        return false;
    }
};

// --- Unit Tests ---

test "ctoon allocator bridge test" {
    const allocator = std.testing.allocator;
    current_allocator = allocator;
    defer current_allocator = null;

    // Create a value object using toon.h C API
    const obj = c.toon_value_object() orelse return error.OutOfMemory;
    defer c.toon_value_free(obj);

    // Set "workout" field
    const workout_slot = c.toon_obj_set(obj, "workout") orelse return error.OutOfMemory;
    workout_slot.*.type = c.TOON_STRING;
    const local_toon_strdup = struct {
        fn dup(s: [:0]const u8) ?[*]u8 {
            const len = s.len;
            const ptr = spline_c_alloc(len + 1) orelse return null;
            const bytes = @as([*]u8, @ptrCast(ptr));
            @memcpy(bytes[0..len], s);
            bytes[len] = 0;
            return bytes;
        }
    }.dup;

    workout_slot.*.unnamed_0.str_val = local_toon_strdup("Push Day A");

    // Encode
    var opts = c.toon_encoder_opts{
        .indent_size = 2,
        .delimiter = ',',
        .key_folding = 0,
        .flatten_depth = -1,
    };
    const out = c.toon_encode(obj, &opts);
    defer spline_c_free(out); // Use our custom free

    const out_slice = std.mem.span(out);
    try std.testing.expect(std.mem.indexOf(u8, out_slice, "workout: Push Day A") != null or std.mem.indexOf(u8, out_slice, "workout:Push Day A") != null);
}

test "SQLite wrapper unit test" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Open an in-memory database for testing
    var db = try SqliteDb.open(":memory:");
    defer db.close();

    try db.execute("CREATE TABLE ai_prescriptions (id INTEGER PRIMARY KEY, split_name TEXT, toon_context TEXT, ai_recommendation TEXT);");
    try std.testing.expectEqual(false, try db.prescriptionExists("Push Day A", "workout: Push Day A"));
    try db.insertPrescription("Push Day A", "workout: Push Day A", "Bench Press target: 105kg x 5 reps");
    try std.testing.expectEqual(true, try db.prescriptionExists("Push Day A", "workout: Push Day A"));
}
