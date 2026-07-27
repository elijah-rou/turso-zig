pub const DatabaseState = struct {
    active_connections: usize = 0,
};

pub const CallbackGuardSnapshot = struct {
    active: bool,
    violation: bool,
};

pub const ConnectionState = struct {
    active_statements: usize = 0,
    callback_active: bool = false,
    callback_violation: bool = false,

    pub fn enterCallback(self: *ConnectionState) CallbackGuardSnapshot {
        const snapshot: CallbackGuardSnapshot = .{
            .active = self.callback_active,
            .violation = self.callback_violation,
        };
        self.callback_active = true;
        self.callback_violation = false;
        return snapshot;
    }

    pub fn leaveCallback(self: *ConnectionState, snapshot: CallbackGuardSnapshot) bool {
        const violated = self.callback_violation;
        self.callback_active = snapshot.active;
        self.callback_violation = snapshot.violation or (snapshot.active and violated);
        return violated;
    }

    pub fn recordCallbackViolation(self: *ConnectionState) void {
        self.callback_violation = true;
    }
};
