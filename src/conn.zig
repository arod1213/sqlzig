const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c = @import("sqlite");

const Callback = ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int;
fn emptyCallback(_: ?*anyopaque, _: c_int, _: [*c][*c]u8, _: [*c][*c]u8) callconv(.c) c_int {
    return 0;
}

const OK = c.SQLITE_OK;
pub const Connection = struct {
    ptr: ?*c.struct_sqlite3 = null,

    const Self = @This();
    pub fn init(name: []const u8) !Self {
        var conn: ?*c.struct_sqlite3 = null;
        const res = c.sqlite3_open(@ptrCast(name), &conn);
        if (res != 0 or conn == null) {
            return error.FailedToOpen;
        }
        return .{
            .ptr = conn,
        };
    }

    pub fn beginTransaction(self: *const Self) !void {
        try self.exec("BEGIN TRANSACTION", emptyCallback);
    }

    pub fn closeTransaction(self: *const Self, success: bool) !void {
        if (success) {
            try self.exec("COMMIT", emptyCallback);
        } else {
            try self.exec("ROLLBACK", emptyCallback);
        }
    }

    pub fn numChanges(self: *const Self) isize {
        return @intCast(c.sqlite3_changes(self.ptr));
    }

    pub fn deinit(self: Self) void {
        if (self.ptr == null) {
            return;
        }

        const res = c.sqlite3_close(self.ptr);
        if (res != 0) {
            const msg = c.sqlite3_errmsg(self.ptr);
            std.log.err("failed to deinit db: {any}", .{msg});
        }
    }

    pub fn exec(self: Self, sql: [:0]const u8) !void {
        const res = c.sqlite3_exec(self.ptr, @ptrCast(sql), emptyCallback, null, null);
        if (res != c.SQLITE_OK) {
            const msg = c.sqlite3_errmsg(self.ptr);
            std.log.err("failed to exec sql: {any} {d}", .{ msg, res });
            return error.SQLFailed;
        }
    }
};
