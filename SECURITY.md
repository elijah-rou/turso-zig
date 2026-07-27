# Security policy

## Supported versions

No released version is currently supported. The current pre-release binding
covers the complete pinned Turso SDK Kit 0.7.1 ABI, but has not received a
production security audit or compatibility guarantee beyond that exact ABI.

The safe API validates ownership, diagnostics, callback boundaries, and native
status conversion. It cannot make the linked Turso engine, application-provided
callbacks, VFS implementations, or loaded native extensions memory-safe.
`Connection.loadExtensionUnsafe` executes arbitrary native code with the
process's privileges and provides no sandbox, transactional rollback, or safe
unload. Treat the native library path, extension paths, callback code, database
files, and encryption keys as trust boundaries. Raw declarations under
`turso.c` remain unstable and unsafe despite parity classification.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private
security advisory flow for this repository once its remote is configured. If
private reporting is unavailable, contact the repository owner privately.

Include the affected revision, target platform, reproduction steps, expected
impact, and whether the issue crosses the Zig/C/Rust ownership boundary. Do not
include live credentials or production database contents.

Turso engine vulnerabilities should also be reported through Turso's upstream
security process: <https://github.com/tursodatabase/turso/security>.
