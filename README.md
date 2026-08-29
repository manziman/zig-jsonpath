# zig-jsonpath
A Zig JSONPath library that implements the IETF RFC 9535. 

## Testing

Run the unit tests with Zig 0.16.0 or later:

```sh
zig build test
```

The official JSONPath Compliance Test Suite is pinned as a git submodule at
revision `7be7c1fc28057c91e8eefaf197060fba7ed43acd`. Initialize it once after
cloning, then run the entire suite with one process-isolated worker per case:

```sh
git submodule update --init
zig build cts
```

The pinned suite contains 456 valid selectors and 247 invalid selectors. The
current safety baseline is:

- 109 valid passes
- 347 valid failures
- 128 invalid selectors rejected
- 119 invalid selectors accepted
- 0 crashes

The same counts are expected in Debug and ReleaseSafe. The CTS target reports
semantic failures without failing the build; it returns a failure only if a
case crashes or the harness cannot obtain a valid worker result. Broad semantic
conformance changes are tracked separately from this safety baseline.

## TODO
### Basic Functionality
- [x] Implement * operator (select all members at current node)
- [x] Implement selector filter for objects in addition to arrays
- [x] Implement support for JSONpath root-level comparison expressions
### Filter Expressions
- [x] count() builtin function
- [x] length() builtin function
- [x] match() builtin function
- [x] search() builtin function
- [x] value() builtin function
- [x] Regular expression pattern matching
### Misc
- [x] Release automation
- [ ] Add inline documentation
### Testing
- [ ] Add tests for all examples in the RFC
