const std = @import("std");
const sqlzig = @import("sqlzig");

const Connection = sqlzig.Connection;
const Statement = sqlzig.Statement;

const Abc = struct {
    id: u64,
    older: bool,
    name: []const u8,
};

pub fn insert(conn: *const Connection) !void {
    const data = [_]Abc{
        .{ .id = 8, .name = "john", .older = false },
        .{ .id = 10, .name = "jacob", .older = true },
    };

    const sql = "INSERT INTO files (id, name, older) VALUES (@id, @name, @older)";
    const stmt = try Statement.init(conn, sql);
    defer stmt.deinit() catch {};
    for (data) |d| {
        defer stmt.reset() catch {};
        // try stmt.bindStruct(d);
        try stmt.bindParam("@id", d.id);
        try stmt.bindParam(2, d.name);
        try stmt.bindParam(3, d.older);
        _ = try stmt.exec();
    }
}

pub fn insertALot(conn: *const Connection) !void {
    try conn.beginTransaction();
    errdefer conn.closeTransaction(false) catch {};

    const sql = "INSERT INTO files (id, name, older) VALUES (@id, @name, @older)";
    const stmt = try Statement.init(conn, sql);
    defer stmt.deinit() catch {};

    for (0..5000000) |idx| {
        const d: Abc = .{ .id = @intCast(idx), .name = "john", .older = false };
        defer stmt.reset() catch {};
        // try stmt.bindStruct(d);
        try stmt.bindParam(1, d.id);
        try stmt.bindParam("@name", d.name);
        try stmt.bindParam(3, d.older);
        _ = try stmt.exec();
    }
    try conn.closeTransaction(true);
}

pub fn bindStruct(conn: *const Connection) !void {
    const sql = "SELECT id, older, name FROM files LIMIT 1";
    const stmt = try Statement.init(conn, sql);
    defer stmt.deinit() catch {};
    _ = try stmt.exec();

    const val = try stmt.readStruct(Abc);
    std.log.info("val is {any}", .{val});
}

pub fn query(conn: *const Connection) !void {
    const sql = "SELECT id, older, name FROM files LIMIT 1";
    const stmt = try Statement.init(conn, sql);
    defer stmt.deinit() catch {};
    _ = try stmt.exec();

    const id = try stmt.readColumn(u64, 0);
    const older = try stmt.readColumn(bool, 1);
    const name = try stmt.readColumn([]const u8, 2);
    const val = Abc{
        .id = id,
        .older = older,
        .name = name,
    };
    std.log.info("val is {any}", .{val});
}

pub fn main() !void {
    const conn = try Connection.init("./test.db");
    defer conn.deinit();

    const migration = "CREATE TABLE IF NOT EXISTS files ( id INT not null, name TEXT not null, older INT not null)";
    try conn.exec(migration);

    // try sqlzig.insertALot(&conn);
    // try query(&conn);
    try bindStruct(&conn);
    // try sqlzig.insert(&conn);
}
