const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c = @import("lib.zig").c;
const parameters = @import("param.zig");

const Callback = ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int;
pub fn emptyCallback(_: ?*anyopaque, _: c_int, _: [*c][*c]u8, _: [*c][*c]u8) callconv(.c) c_int {
    return 0;
}

const OK = c.SQLITE_OK;
pub const Conn = struct {
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

    pub fn execParams(self: Self, alloc: Allocator, sql: [:0]const u8, params: anytype) !void {
        const info = @typeInfo(@TypeOf(params));
        assert(info == .@"struct");
        const struct_params = try parameters.structToParams(alloc, params);

        const sql_stmt = try std.mem.join(alloc, "", &[_][]const u8{ sql, "(", struct_params, ")" });
        std.log.info("stmt is: {s}", .{sql_stmt});
        try self.exec(@ptrCast(sql_stmt), emptyCallback);
    }

    pub fn exec(self: Self, sql: [:0]const u8, callback: Callback) !void {
        const res = c.sqlite3_exec(self.ptr, @ptrCast(sql), callback, null, null);
        if (res != c.SQLITE_OK) {
            const msg = c.sqlite3_errmsg(self.ptr);
            std.log.err("failed to exec sql: {any} {d}", .{ msg, res });
            return error.SQLFailed;
        }
    }
};

pub const Statement = struct {
    ptr: ?*c.sqlite3_stmt,

    const Self = @This();
    pub fn init(conn: *const Conn, sql: [:0]const u8) !Self {
        var ptr: ?*c.sqlite3_stmt = undefined;
        const res = c.sqlite3_prepare(conn.ptr, sql, -1, &ptr, null);
        if (res != OK) return error.FailedPrepare;
        return .{
            .ptr = ptr,
        };
    }

    pub fn close(self: *const Self) !void {
        const res = c.sqlite3_finalize(self.ptr);
        if (res != OK) return error.FailedClose;
    }

    pub fn reset(self: *const Self) !void {
        const res = c.sqlite3_reset(self.ptr);
        if (res != OK) return error.FailedClose;
    }

    pub fn exec(self: *const Self) !void {
        const res = c.sqlite3_step(self.ptr);
        if (res != c.SQLITE_DONE) return error.FailedStmt;
    }

    pub fn bindStruct(self: *const Self, x: anytype) !void {
        const info = @typeInfo(@TypeOf(x));
        assert(info == .@"struct");
        inline for (info.@"struct".fields) |field| {
            const param_name = "@" ++ field.name;
            const idx = try self.namedParamIndex(@ptrCast(param_name));
            try self.bindParam(idx, @field(x, field.name));
        }
    }

    pub fn bindParam(self: *const Self, idx: c_int, param: anytype) !void {
        const info = @typeInfo(@TypeOf(param));
        std.log.info("type is {any}", .{info});
        const res = switch (info) {
            .int, .comptime_int => c.sqlite3_bind_int(self.ptr, idx, @intCast(param)),
            .float, .comptime_float => c.sqlite3_bind_double(self.ptr, idx, @floatCast(param)),
            .bool => c.sqlite3_bind_int(self.ptr, idx, @intFromBool(param)),
            .pointer => |ptr| if (ptr.child == u8) c.sqlite3_bind_text(self.ptr, idx, @ptrCast(param), @intCast(param.len), null) else return error.Unsupported,
            else => return error.Unsupported,
        };
        if (res != OK) return error.FailedPrepare;
    }

    pub fn namedParamIndex(self: *const Self, name: [:0]const u8) !c_int {
        const idx = c.sqlite3_bind_parameter_index(self.ptr, name);
        if (idx == 0) {
            std.log.err("failed to find {s}", .{name});
            return error.InvalidName;
        }
        return idx;
    }
};
