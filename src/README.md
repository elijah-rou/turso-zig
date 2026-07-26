# Source layout

The implemented synchronous SDK is split at ownership boundaries:

- `root.zig`: public exports, pinned ABI version, and runtime compatibility check.
- `c_api.zig`: the sole `@cImport` of vendored `turso.h` plus compile-time tag checks; exported as the unstable `turso.c` namespace.
- `error.zig`: exhaustive status mapping and copy/free handling for Turso diagnostics.
- `value.zig`: `Value`, whose text/blob variants own allocator-copied bytes.
- `database.zig`: copied configuration, create/open/connect/deinit, construction failures, and database diagnostics.
- `connection.zig`: prepare, busy timeout, transaction state, close/deinit, and connection diagnostics.
- `statement.zig`: positional binding, execute/step/reset/finalize, copied values and metadata, and statement diagnostics.

`Database`, `Connection`, and `Statement` own opaque native handles. They are
non-copyable by contract: an ordinary move transfers ownership, including when
a parent already has live children, but using copied aliases is programmer
misuse. Use pointer-receiver methods after the move. Statements must be
deinitialized before their connection and connections before their database.
Connections and statements are exclusive-use; no wrapper adds locking or async
execution.

Raw pointers and C-allocated strings stay at the ABI boundary. Row text/blob
and metadata are copied before Turso-owned storage is released or invalidated.
Cloud sync, callbacks, extensions, and async I/O are outside the implemented v0
surface.
