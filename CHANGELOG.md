# Changelog

Notable changes will be documented here. This project follows
[Semantic Versioning](https://semver.org/) after its first public release.

## Unreleased

### Added

- Complete pre-release Zig 0.16.0 safe adapter for all 48 functions and 27 typedefs in the pinned Turso SDK Kit 0.7.1 C ABI.
- Machine-checked ABI inventory, declaration signatures, callback layouts, managed scalar/aggregate/collation adapters, caller-driven statement progress, extension controls, examples, and native distribution guidance.

### Security

- Explicitly classify direct extension loading as an unsafe arbitrary-native-code trust boundary.
- Enforce bounded callback values, managed callback ownership, checked diagnostics, and reverse-order native handle teardown.
