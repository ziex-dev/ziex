const Mysql = mysql.Backend(Db);

const std = @import("std");
const mysql = @import("db_mysql");
const Db = @import("../Db.zig");

pub const OpenOptions = Mysql.OpenOptions;
pub const open = Mysql.open;
pub const deserialize = Mysql.deserialize;
pub const db = Mysql.db;
pub const from = Mysql.from;
pub const uri = mysql.uri;
