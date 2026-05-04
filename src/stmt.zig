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

    pub fn close(self: *const Self) !void {
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
                const digit: u2 = @intCast(c.sqlite3_column_int(self.ptr, idx));
                if (digit == 1) return true else return false;
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
            const idx = try self.namedParamIndex(@ptrCast(param_name));
            try self.bindParam(idx, @field(x, field.name));
        }
    }

    pub fn bindParam(self: *const Self, pos: anytype, param: anytype) !void {
        const T = @TypeOf(param);
        const info = @typeInfo(T);
        const idx = try param_index(self.ptr, pos);

        const res = switch (info) {
            .int, .comptime_int => blk: {
                if (T == u64 or T == i64) {
                    break :blk c.sqlite3_bind_int64(self.ptr, idx, @intCast(param));
                } else {
                    break :blk c.sqlite3_bind_int(self.ptr, idx, @intCast(param));
                }
            },
            .float, .comptime_float => c.sqlite3_bind_double(self.ptr, idx, @floatCast(param)),
            .bool => c.sqlite3_bind_int(self.ptr, idx, @intFromBool(param)),
            .pointer, .array => c.sqlite3_bind_text(self.ptr, idx, @ptrCast(param), @intCast(param.len), null),
            else => return error.Unsupported,
        };
        if (res != OK) return error.FailedPrepare;
    }
};
