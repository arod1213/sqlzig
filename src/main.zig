const std = @import("std");
const sqlzig = @import("sqlzig");

const Conn = sqlzig.Conn;
const ParamType = sqlzig.ParamType;
const NamedParam = sqlzig.NamedParam;

const Abc = struct {
    id: i8 = 8,
    older: bool = false,
    name: []const u8 = "aidan",
};

const nothing = sqlzig.emptyCallback;
pub fn main() !void {
    const conn = try Conn.init("./test.db");
    defer conn.deinit();

    const migration = "CREATE TABLE IF NOT EXISTS files ( id INT not null, name TEXT not null, older INT not null)";
    try conn.exec(migration, nothing);

    const data = [_]Abc{ .{}, .{ .id = 10, .name = "other", .older = true } };

    const sql = "INSERT INTO files (id, name, older) VALUES (?, ?, ?)";
    const stmt = try sqlzig.Statement.init(&conn, sql);
    for (data) |d| {
        defer stmt.reset() catch {};
        try stmt.bindParam(1, d.id);
        try stmt.bindParam(2, d.name);
        try stmt.bindParam(3, d.older);
        try stmt.exec();
    }
    try stmt.close();
}
