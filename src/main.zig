const std = @import("std");
const sqlzig = @import("sqlzig");

const Conn = sqlzig.Conn;
const Statement = sqlzig.Statement;

const Abc = struct {
    id: i8,
    older: bool,
    name: []const u8,
};

pub fn insert(conn: *const Conn) !void {
    const data = [_]Abc{
        .{ .id = 8, .name = "john", .older = false },
        .{ .id = 10, .name = "jacob", .older = true },
    };
    const sql = "INSERT INTO files (id, name, older) VALUES (@id, @name, @older)";
    const stmt = try Statement.init(conn, sql);
    defer stmt.close() catch {};
    for (data) |d| {
        defer stmt.reset() catch {};
        try stmt.bindStruct(d);
        // try stmt.bindParam(1, d.id);
        // try stmt.bindParam(2, d.name);
        // try stmt.bindParam(3, d.older);
        _ = try stmt.exec();
    }
}

pub fn query(conn: *const Conn) !void {
    const sql = "SELECT id, older, name FROM files LIMIT 1";
    const stmt = try Statement.init(conn, sql);
    defer stmt.close() catch {};
    _ = try stmt.exec();
    // const val = try stmt.readColumn(i8, 0);
    const val = try stmt.readStruct(Abc);
    std.log.info("val is {any}", .{val});
}

const nothing = sqlzig.emptyCallback;
pub fn main() !void {
    const conn = try Conn.init("./test.db");
    defer conn.deinit();

    const migration = "CREATE TABLE IF NOT EXISTS files ( id INT not null, name TEXT not null, older INT not null)";
    try conn.exec(migration, nothing);

    // try insert(&conn);
    try query(&conn);
}
