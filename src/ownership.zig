const std = @import("std");

pub const DatabaseState = struct {
    active_connections: usize = 0,
};

pub const CallbackGuardSnapshot = struct {
    active: bool,
    violation: bool,
};

pub const max_aggregate_registrations: usize = 4096;
pub const max_active_statements: usize = 4096;

pub const StatementProgressRecord = struct {
    native_handle_key: usize,
    next: ?*StatementProgressRecord = null,
};

pub const AggregateRegistration = struct {
    next: ?*AggregateRegistration = null,
    reclaim_states: *const fn (registration: *AggregateRegistration) void,
};

fn statementProgressHead(state: *const ConnectionState) ?*StatementProgressRecord {
    const opaque_head = state.statement_progress_records orelse return null;
    return @ptrCast(@alignCast(opaque_head));
}

pub const ConnectionState = struct {
    active_statements: usize = 0,
    callback_active: bool = false,
    callback_violation: bool = false,
    aggregate_registrations: ?*AggregateRegistration = null,
    aggregate_registration_count: usize = 0,
    statement_progress_records: ?*anyopaque = null,

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

    pub fn canRegisterStatement(self: *const ConnectionState) bool {
        return self.active_statements < max_active_statements;
    }

    pub fn addStatementProgressRecord(self: *ConnectionState, record: *StatementProgressRecord) void {
        std.debug.assert(self.canRegisterStatement());
        std.debug.assert(record.next == null);
        std.debug.assert(findStatementProgressRecord(self, record.native_handle_key) == null);
        record.next = statementProgressHead(self);
        self.statement_progress_records = record;
        self.active_statements += 1;
        std.debug.assert(self.active_statements <= max_active_statements);
    }

    pub fn findStatementProgressRecord(self: *const ConnectionState, native_handle_key: usize) ?*StatementProgressRecord {
        var record = statementProgressHead(self);
        var visited: usize = 0;
        while (record) |current| {
            std.debug.assert(visited < max_active_statements);
            if (current.native_handle_key == native_handle_key) return current;
            record = current.next;
            visited += 1;
        }
        std.debug.assert(visited == self.active_statements);
        return null;
    }

    pub fn removeStatementProgressRecord(self: *ConnectionState, native_handle_key: usize) *StatementProgressRecord {
        std.debug.assert(self.active_statements > 0);
        var link: *?*StatementProgressRecord = @ptrCast(&self.statement_progress_records);
        var visited: usize = 0;
        while (link.*) |current| {
            std.debug.assert(visited < max_active_statements);
            if (current.native_handle_key == native_handle_key) {
                link.* = current.next;
                current.next = null;
                self.active_statements -= 1;
                return current;
            }
            link = &current.next;
            visited += 1;
        }
        std.debug.assert(false);
        unreachable;
    }

    pub fn canRegisterAggregate(self: *const ConnectionState) bool {
        return self.aggregate_registration_count < max_aggregate_registrations;
    }

    pub fn addAggregateRegistration(self: *ConnectionState, registration: *AggregateRegistration) void {
        std.debug.assert(self.canRegisterAggregate());
        std.debug.assert(registration.next == null);
        registration.next = self.aggregate_registrations;
        self.aggregate_registrations = registration;
        self.aggregate_registration_count += 1;
        std.debug.assert(self.aggregate_registration_count <= max_aggregate_registrations);
    }

    pub fn removeAggregateRegistration(self: *ConnectionState, registration: *AggregateRegistration) void {
        std.debug.assert(self.aggregate_registration_count > 0);
        var link = &self.aggregate_registrations;
        while (link.*) |candidate| {
            if (candidate == registration) {
                link.* = candidate.next;
                registration.next = null;
                self.aggregate_registration_count -= 1;
                return;
            }
            link = &candidate.next;
        }
        std.debug.assert(false);
    }

    pub fn reclaimAggregateStates(self: *ConnectionState) void {
        std.debug.assert(self.active_statements == 0);
        std.debug.assert(self.statement_progress_records == null);
        var registration = self.aggregate_registrations;
        var visited: usize = 0;
        while (registration) |current| {
            std.debug.assert(visited < max_aggregate_registrations);
            const next = current.next;
            current.reclaim_states(current);
            registration = next;
            visited += 1;
        }
        std.debug.assert(visited == self.aggregate_registration_count);
    }
};
