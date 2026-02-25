const std = @import("std");
const c = @import("lib.zig").c;

fn tryResult(res: c_int) !void {
    if (res != c.SQLITE_OK) {
        return error.Failed;
    }
}

fn callback(_: ?*anyopaque, _: c_int, _: [*c][*c]u8, _: [*c][*c]u8) callconv(.c) c_int {
    return 0;
}

fn bindValue(stmt: ?*c.sqlite3_stmt, idx: usize, val: ParamType) !void {
    const pos: c_int = @intCast(idx);
    const rc = switch (val) {
        .float => |x| c.sqlite3_bind_double(stmt, pos, x),
        .int => |x| c.sqlite3_bind_int(stmt, pos, x),
        .str => |x| c.sqlite3_bind_text(stmt, pos, @ptrCast(x), -1, c.SQLITE_STATIC),
        .none => c.sqlite3_bind_null(stmt, pos),
        .any => |x| c.sqlite3_bind_blob(stmt, pos, x, @sizeOf(@TypeOf(x)), c.SQLITE_STATIC),
    };
    if (rc != c.SQLITE_OK) {
        return error.FailedToBind;
    }
}

fn nameIndex(stmt: ?*c.sqlite3_stmt, name: [:0]const u8) !c_int {
    const index = c.sqlite3_bind_parameter_index(stmt, @ptrCast(name));
    if (index == 0) {
        return error.BadParam;
    }
    return index;
}

pub const NamedParam = struct {
    name: [:0]const u8,
    value: ParamType,
};

pub const ParamType = union(enum) {
    int: c_int,
    float: f64,
    str: [:0]const u8,
    any: ?*anyopaque,
    none,

    const Self = @This();
    pub fn format(self: Self, w: *std.Io.Writer) !void {
        switch (self) {
            .str => |x| try w.print("str of {s}\n", .{x}),
            .int => |x| try w.print("int of {d}\n", .{x}),
            .float => |x| try w.print("float of {d}\n", .{x}),
        }
    }
};
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

    pub fn statementNamed(self: Self, sql: [:0]const u8, params: []const NamedParam) !void {
        var stmt: ?*c.sqlite3_stmt = undefined;
        const res = c.sqlite3_prepare_v2(self.ptr, @ptrCast(sql), -1, &stmt, null);
        if (res != 0) {
            const msg = c.sqlite3_errmsg(self.ptr);
            std.log.err("err preparing {any} {d}\n", .{ msg, res });
            return error.FailedToPrepare;
        }

        for (params) |p| {
            const idx = try nameIndex(stmt, p.name);
            try bindValue(stmt, @intCast(idx), p.value);
        }

        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            const msg = c.sqlite3_errmsg(self.ptr);
            std.log.err("failed to exec sql: {s}", .{msg});
            return error.FailedToExecute;
        }
        _ = c.sqlite3_finalize(stmt);
    }

    pub fn statement(self: Self, sql: [:0]const u8, params: []const ParamType) !void {
        var stmt: ?*c.sqlite3_stmt = undefined;
        const res = c.sqlite3_prepare_v2(self.ptr, @ptrCast(sql), -1, &stmt, null);
        if (res != 0) {
            const msg = c.sqlite3_errmsg(self.ptr);
            std.log.err("err preparing {any} {d}\n", .{ msg, res });
            return error.FailedToPrepare;
        }

        for (params, 1..) |val, idx| {
            try bindValue(stmt, idx, val);
        }

        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) {
            const msg = c.sqlite3_errmsg(self.ptr);
            std.log.err("failed to exec prepared sql: {s}", .{msg});
            return error.FailedToExecute;
        }
        _ = c.sqlite3_finalize(stmt);
    }

    pub fn exec(self: Self, sql: [:0]const u8) !void {
        const res = c.sqlite3_exec(self.ptr, @ptrCast(sql), callback, null, null);
        if (res != c.SQLITE_OK) {
            const msg = c.sqlite3_errmsg(self.ptr);
            std.log.err("failed to exec sql: {any} {d}", .{ msg, res });
            return error.SQLFailed;
        }
    }
};
