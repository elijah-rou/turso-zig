## Summary

Describe the public contract or repository behavior changed and why.

## ABI and ownership

Describe any C ABI, allocation, lifetime, concurrency, or target-support impact.
Write `None` when not applicable.

## Verification

List fresh commands and results.

- [ ] `zig fmt --check build.zig` plus all changed Zig sources
- [ ] `zig build`
- [ ] Tests cover observable behavior when behavior changed
- [ ] No native binaries, credentials, or database files are included
