# Contributing

## Requirements

- Zig 0.16.0
- Git
- A C toolchain when native Turso linking is introduced
- Rust and Cargo only when explicitly building Turso from source

The SDK has not implemented its public API yet. Read
[`docs/implementation-plan.md`](docs/implementation-plan.md) before proposing
API or ownership changes.

## Development

Fork or clone the repository, create a focused branch, and run:

```sh
zig fmt --check build.zig
zig build
git diff --check
```

As Zig sources are added, include every touched `.zig` file in the format check.
Behavior changes require a failing public-contract test before the fix. Keep raw
C pointers and C string handling inside the FFI boundary.

## Pull requests

Keep each pull request to one concern. Include:

- the user-visible contract being added or changed;
- C ABI ownership or lifetime implications;
- exact validation commands and results; and
- supported targets affected by the change.

Do not commit Turso native binaries, authentication tokens, local databases, or
Zig build output.

## Commit messages

Use a short imperative subject with an optional scope, for example:

```text
statement: copy text values before stepping
```

Explain the invariant or compatibility reason in the body when the subject is
not sufficient.
