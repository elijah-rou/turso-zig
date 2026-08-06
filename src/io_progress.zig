pub const IoMode = enum {
    library_driven,
    caller_driven,
};

pub const OpenProgress = enum {
    ready,
    needs_io_without_driver,
};

pub const StepProgress = enum {
    row,
    done,
    needs_io,
};

pub const ExecuteProgress = union(enum) {
    done: u64,
    needs_io,
};

pub const FinalizeProgress = enum {
    done,
    needs_io,
};
