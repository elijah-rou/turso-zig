# Zig SDK implementation notes

This directory contains design and release guidance, not generated bindings or
an SDK implementation.

- [`implementation-plan.md`](implementation-plan.md): ordered implementation
  plan, API boundary, C-ABI ownership rules, and tests.
- [`distribution.md`](distribution.md): options for making the Turso native
  library available to Zig consumers and the release matrix.

The source-of-truth native interface is Turso's
[`sdk-kit/turso.h`](https://github.com/tursodatabase/turso/blob/main/sdk-kit/turso.h).
Treat it as an ABI contract: do not infer ownership or valid handle state from
another language binding.
