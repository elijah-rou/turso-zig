# Source layout

The implemented synchronous SDK is split at ownership boundaries:

- `root.zig`: public exports, pinned ABI version, and runtime compatibility check.
- `c_api.zig`: the sole `@cImport` of vendored `turso.h` plus compile-time tag checks; exported as the unstable `turso.c` namespace.
- `error.zig`: exhaustive status mapping and copy/free handling for Turso diagnostics.
- `setup.zig`: safe version access, owned setup failures, and the synchronized process-global logger trampoline.
- `value.zig`: `Value`, whose text/blob variants own allocator-copied bytes.
- `callback_value.zig`: exhaustive borrowed callback values and bounded, owned result encoding.
- `database.zig`: copied configuration, create/open/connect/deinit, construction failures, and database diagnostics.
- `connection.zig`: prepare, managed scalar registration policy, busy timeout, transaction state, close/deinit, and connection diagnostics.
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
Logger record slices are the exception: they are invocation-borrowed, validated,
and bounded because the native logger ABI provides no ownership transfer.
Empty logger strings and zero timestamp or line values are valid. Setup
serializes its bounded process-global state. Its first successful level wins,
while later successful calls may replace the process-lifetime plain logger
function pointer. A null logger preserves the installed callback, or installs
none when no callback exists. Loggers must be thread-safe and non-panicking;
they must not call `setup`, which rejects logger-callback reentry with
`InvalidState`.

Managed scalar callback contexts transfer to native ownership only after raw
`TURSO_OK`; failed registration leaves context cleanup with the caller. Result
destructors release nested package allocations, never Turso's stack result
pointer. Callback and context-deinit execution blocks native re-entry through
the owning connection and all of its statements. Turso 0.7.1 callback arguments
lose JSON subtype and never carry managed ERROR values; decoding those ABI tags
remains defensive source-level coverage.

Cloud sync, aggregate and collation callbacks, loadable extensions, and async
I/O are outside the implemented v0 surface.
