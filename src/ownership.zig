pub const DatabaseState = struct {
    active_connections: usize = 0,
};

pub const ConnectionState = struct {
    active_statements: usize = 0,
    callback_active: bool = false,
};
