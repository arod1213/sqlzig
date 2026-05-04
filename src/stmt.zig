const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c = @import("sqlite");
const connection = @import("./conn.zig");
const Connection = connection.Connection;

const StatementRes = enum(c_int) {
    done = c.SQLITE_DONE,
    row = c.SQLITE_ROW,
};

fn param_name_ptr(pos: anytype) ?[*:0]const u8 {
    const T = @TypeOf(pos);
    return switch (@typeInfo(T)) {
        .array => |arr| if (arr.child == u8 and arr.sentinel() == 0) @ptrCast(&pos) else null,
        .pointer => |ptr| switch (ptr.size) {
            .one => blk: {
                if (ptr.child == u8 and ptr.sentinel() == 0) break :blk pos;

                const child = @typeInfo(ptr.child);
                if (child == .array and child.array.child == u8 and child.array.sentinel() == 0) {
                    break :blk @ptrCast(pos);
                }

                break :blk null;
            },
            .many => if (ptr.child == u8 and ptr.sentinel() == 0) pos else null,
            .slice => if (ptr.child == u8 and ptr.sentinel() == 0) pos.ptr else null,
            .c => if (ptr.child == u8) @ptrCast(pos) else null,
        },
        else => null,
    };
}

fn param_index(stmt: ?*c.sqlite3_stmt, pos: anytype) !c_int {
    const info = @typeInfo(@TypeOf(pos));

    const idx = blk: switch (info) {
        .int => |x| @as(c_int, @intCast(x)),
        .comptime_int => @as(c_int, @intCast(pos)),
        .pointer, .array => {
            const name: [*c]const u8 = @ptrCast(pos);
            break :blk c.sqlite3_bind_parameter_index(stmt, name);
        },
        else => return error.UnsupportedIndex,
    };

    if (idx == 0) {
        return error.BadIndex;
    }

    return idx;
}

const OK = c.SQLITE_OK;
pub const Bindable = union(enum) { named: []const u8, pos: c_int };
pub const Statement = struct {
    ptr: ?*c.sqlite3_stmt,

    const Self = @This();
    pub fn init(conn: *const Connection, sql: [:0]const u8) !Self {
        var ptr: ?*c.sqlite3_stmt = undefined;
        const res = c.sqlite3_prepare_v3(conn.ptr, sql, -1, 0, &ptr, null);
        if (res != OK) return error.FailedPrepare;
        return .{
            .ptr = ptr,
        };
    }

    pub fn deinit(self: *const Self) !void {
        const res = c.sqlite3_finalize(self.ptr);
        if (res != OK) return error.FailedClose;
    }

    pub fn reset(self: *const Self) !void {
        const res = c.sqlite3_reset(self.ptr);
        if (res != OK) return error.FailedClose;
    }

    pub fn exec(self: *const Self) !StatementRes {
        const res = c.sqlite3_step(self.ptr);
        return std.enums.fromInt(StatementRes, res) orelse return error.FailedStmt;
    }

    pub fn readStruct(self: *const Self, comptime T: type) !T {
        const info = @typeInfo(T);
        assert(info == .@"struct");
        var target: T = undefined;
        inline for (info.@"struct".fields, 0..) |field, idx| {
            const val = try self.readColumn(field.type, @intCast(idx));
            @field(target, field.name) = val;
        }
        return target;
    }

    pub fn readColumn(self: *const Self, comptime T: type, idx: c_int) !T {
        const info = @typeInfo(T);
        return switch (info) {
            .int, .comptime_int => @intCast(c.sqlite3_column_int(self.ptr, idx)),
            .float, .comptime_float => @floatCast(c.sqlite3_column_double(self.ptr, idx)),
            .bool => {
                return switch (c.sqlite3_column_int(self.ptr, idx)) {
                    1 => true,
                    0 => false,
                    else => return error.InvalidBool,
                };
            },
            .pointer => |ptr| if (ptr.child == u8) {
                const c_str = c.sqlite3_column_text(self.ptr, idx);
                if (c_str == null) return error.BadString;
                return std.mem.span(c_str);
            },
            else => return error.Unsupported,
        };
    }

    pub fn bindStruct(self: *const Self, x: anytype) !void {
        const info = @typeInfo(@TypeOf(x));
        assert(info == .@"struct");
        inline for (info.@"struct".fields) |field| {
            const param_name = "@" ++ field.name;
            try self.bindParam(param_name, @field(x, field.name));
        }
    }

    pub fn bindParam(self: *const Self, pos: anytype, param: anytype) !void {
        const idx = try param_index(self.ptr, pos);
        try bindValue(self.ptr, idx, param);
    }
};

fn bindValue(stmt: ?*c.sqlite3_stmt, idx: c_int, param: anytype) !void {
    const T = @TypeOf(param);
    const info = @typeInfo(T);
    const res = switch (info) {
        .int, .comptime_int => blk: {
            if (T == u64 or T == i64) {
                break :blk c.sqlite3_bind_int64(stmt, idx, @intCast(param));
            } else {
                break :blk c.sqlite3_bind_int(stmt, idx, @intCast(param));
            }
        },
        .float, .comptime_float => c.sqlite3_bind_double(stmt, idx, @floatCast(param)),
        .bool => c.sqlite3_bind_int(stmt, idx, @intFromBool(param)),
        .@"enum" => blk: {
            const enum_int = @intFromEnum(param);
            break :blk c.sqlite3_bind_int(stmt, idx, @intCast(enum_int));
        },
        .optional => blk: {
            if (param == null) {
                break :blk c.sqlite3_bind_null(stmt, idx);
            } else {
                break :blk bindValue(stmt, idx, param.?);
            }
        },
        .pointer => blk: {
            break :blk c.sqlite3_bind_text(stmt, idx, @ptrCast(param), @intCast(param.len), null);
        },
        else => return error.Unsupported,
    };

    if (res != OK) return error.FailedPrepare;
}

test "binding" {
    var conn = try Connection.init(":memory:");
    defer conn.deinit();
    const sql =
        \\CREATE TABLE works (
        \\ id TEXT,
        \\ num INTEGER,
        \\ decimal REAL,
        \\ is_valid INTEGER 
        \\)
    ;
    try conn.exec(sql);
    const insert_sql =
        \\
        \\SELECT id FROM works 
        \\WHERE id = @id 
        \\AND num = @num 
        \\AND decimal = @decimal 
        \\AND is_valid = @valid
    ;
    var stmt = try Statement.init(&conn, insert_sql);
    defer stmt.deinit() catch {};
    try stmt.bindParam("@id", "abc");
    try stmt.bindParam("@num", 12389);
    try stmt.bindParam("@decimal", 4.56);
    try stmt.bindParam("@valid", true);
}

test "bind struct" {
    var conn = try Connection.init(":memory:");
    defer conn.deinit();
    const sql =
        \\CREATE TABLE works (
        \\ id TEXT,
        \\ num INTEGER,
        \\ decimal REAL,
        \\ is_valid INTEGER 
        \\)
    ;
    try conn.exec(sql);
    const Input = struct {
        id: []const u8 = "abc",
        num: u32 = 12389,
        decimal: f64 = 4.56,
        valid: bool = true,
    };

    const insert_sql =
        \\
        \\SELECT id FROM works 
        \\WHERE id = @id 
        \\AND num = @num 
        \\AND decimal = @decimal 
        \\AND is_valid = @valid
    ;
    var stmt = try Statement.init(&conn, insert_sql);
    defer stmt.deinit() catch {};
    try stmt.bindStruct(Input{});
}
