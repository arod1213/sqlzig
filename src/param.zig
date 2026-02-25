const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const c = @import("lib.zig").c;

pub fn structToParams(alloc: Allocator, x: anytype) ![]const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(alloc, 5);
    errdefer list.deinit(alloc);

    const info = @typeInfo(@TypeOf(x));
    assert(info == .@"struct");

    inline for (info.@"struct".fields) |field| {
        const field_info = @typeInfo(field.type);
        switch (field_info) {
            .@"struct" => {}, // skip
            else => {
                const str = try paramToStr(alloc, @field(x, field.name));
                try list.append(alloc, str);
            },
        }
    }

    const slice = try list.toOwnedSlice(alloc);
    return try std.mem.join(alloc, ", ", slice);
}

pub fn paramToStr(alloc: Allocator, param: anytype) ![]const u8 {
    const info = @typeInfo(@TypeOf(param));

    return switch (info) {
        .bool => try std.fmt.allocPrint(alloc, "{any}", .{param}),
        .float, .int => try std.fmt.allocPrint(alloc, "{d}", .{param}),
        .pointer => |ptr| {
            if (ptr.child == u8) {
                return param;
            }
            return error.Unsupported;
        },
        else => return error.Unsupported,
    };
}
