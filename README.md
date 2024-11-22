# zig-jsonpath
A Zig JSONPath library that implements the IETF RFC 9535. 

## TODO
### Basic Functionality
- [x] Implement * operator (select all members at current node)
- [x] Implement selector filter for objects in addition to arrays
- [ ] Implement support for JSONpath root-level comparison expressions
### Filter Expressions
- [x] count() builtin function
- [x] length() builtin function
- [ ] match() builtin function
- [ ] search() builtin function
- [ ] value() builtin function
- [ ] Regular expression pattern matching
### Misc
- [x] Release automation
- [ ] Add inline documentation
### Testing
- [ ] Add tests for all examples in the RFC