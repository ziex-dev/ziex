const Postgres = postgres.Backend(Db);

const std = @import("std");
const postgres = @import("db_postgres");
const Db = @import("../Db.zig");

pub const OpenOptions = Postgres.OpenOptions;
pub const open = Postgres.open;
pub const deserialize = Postgres.deserialize;
pub const db = Postgres.db;
pub const from = Postgres.from;
