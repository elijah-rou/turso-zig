# Source layout

Add implementation source here only after the public API in
[`../docs/implementation-plan.md`](../docs/implementation-plan.md) is agreed.

Suggested eventual layout:

- `root.zig`: public exports only.
- `c_api.zig`: narrow declarations corresponding to `sdk-kit/turso.h`.
- `database.zig`, `connection.zig`, `statement.zig`: owning safe wrappers.
- `value.zig`, `error.zig`: SQL value conversion and status/error mapping.
- `sync.zig`: optional cloud-sync API, after local-database support is stable.

Keep raw pointers, C strings, and callback trampolines confined to the FFI
boundary. This is a layout proposal, not an implementation commitment.
