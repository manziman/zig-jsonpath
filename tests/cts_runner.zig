const std = @import("std");
const jsonpath = @import("jsonpath");

const Cts = struct {
    tests: []const TestCase,
};

const TestCase = struct {
    name: []const u8,
    selector: []const u8,
    document: ?std.json.Value = null,
    result: ?[]const std.json.Value = null,
    results: ?[]const []const std.json.Value = null,
    invalid_selector: bool = false,
};

const Outcome = enum {
    valid_pass,
    valid_fail,
    invalid_rejected,
    invalid_accepted,
};

const Counts = struct {
    valid_pass: usize = 0,
    valid_fail: usize = 0,
    invalid_rejected: usize = 0,
    invalid_accepted: usize = 0,
    crash: usize = 0,

    fn record(counts: *Counts, outcome: Outcome) void {
        switch (outcome) {
            .valid_pass => counts.valid_pass += 1,
            .valid_fail => counts.valid_fail += 1,
            .invalid_rejected => counts.invalid_rejected += 1,
            .invalid_accepted => counts.invalid_accepted += 1,
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.MissingCtsPath;

    const cts_path = args[1];
    const cts_source = try readFileAlloc(init.io, arena, cts_path);
    const cts = try std.json.parseFromSliceLeaky(Cts, arena, cts_source, .{
        .ignore_unknown_fields = true,
    });

    if (args.len == 4 and std.mem.eql(u8, args[2], "--worker")) {
        const index = try std.fmt.parseInt(usize, args[3], 10);
        if (index >= cts.tests.len) return error.InvalidCaseIndex;
        return runWorker(arena, init.io, cts.tests[index]);
    }

    if (args.len != 2) return error.InvalidArguments;
    return runController(init.gpa, init.io, args[0], cts_path, cts.tests);
}

fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn runController(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    cts_path: []const u8,
    tests: []const TestCase,
) !u8 {
    var counts: Counts = .{};

    for (tests, 0..) |test_case, index| {
        var index_buffer: [32]u8 = undefined;
        const index_arg = try std.fmt.bufPrint(&index_buffer, "{}", .{index});
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ executable, cts_path, "--worker", index_arg },
            .stdout_limit = .limited(64),
            .stderr_limit = .limited(64 * 1024),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const completed = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!completed) {
            counts.crash += 1;
            std.debug.print("CRASH [{}/{}] {s}\n", .{ index + 1, tests.len, test_case.name });
            if (result.stderr.len > 0) std.debug.print("{s}\n", .{result.stderr});
            continue;
        }

        const outcome_name = std.mem.trim(u8, result.stdout, " \t\r\n");
        const outcome = std.meta.stringToEnum(Outcome, outcome_name) orelse {
            counts.crash += 1;
            std.debug.print("CRASH [{}/{}] {s}: malformed worker output: {s}\n", .{
                index + 1,
                tests.len,
                test_case.name,
                outcome_name,
            });
            continue;
        };
        counts.record(outcome);
    }

    std.debug.print(
        \\JSONPath CTS ({d} cases)
        \\  valid pass:       {d}
        \\  valid fail:       {d}
        \\  invalid rejected: {d}
        \\  invalid accepted: {d}
        \\  crashes:          {d}
        \\
    , .{
        tests.len,
        counts.valid_pass,
        counts.valid_fail,
        counts.invalid_rejected,
        counts.invalid_accepted,
        counts.crash,
    });

    return if (counts.crash == 0) 0 else 1;
}

fn runWorker(allocator: std.mem.Allocator, io: std.Io, test_case: TestCase) !u8 {
    var root = test_case.document orelse std.json.Value.null;
    const selector = try allocator.dupe(u8, test_case.selector);

    const actual = jsonpath.evaluateJsonPathExpression(allocator, selector, &root, .{}) catch {
        return writeOutcome(io, if (test_case.invalid_selector) .invalid_rejected else .valid_fail);
    };

    if (test_case.invalid_selector) return writeOutcome(io, .invalid_accepted);
    return writeOutcome(io, if (matchesExpected(actual, test_case)) .valid_pass else .valid_fail);
}

fn writeOutcome(io: std.Io, outcome: Outcome) !u8 {
    var buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.print("{s}\n", .{@tagName(outcome)});
    try stdout.interface.flush();
    return 0;
}

fn matchesExpected(actual: ?std.json.Value, test_case: TestCase) bool {
    if (test_case.result) |expected| {
        if (matchesNodelist(actual, expected)) return true;
    }
    if (test_case.results) |alternatives| {
        for (alternatives) |expected| {
            if (matchesNodelist(actual, expected)) return true;
        }
    }
    return false;
}

// The legacy API represents both JSON array nodes and nodelists as json.Value.array.
// Until issue #17 separates those concepts, accept either interpretation.
fn matchesNodelist(actual: ?std.json.Value, expected: []const std.json.Value) bool {
    const value = actual orelse return expected.len == 0;

    if (expected.len == 1 and jsonValueEqual(value, expected[0])) return true;
    return switch (value) {
        .array => |array| jsonArrayEqual(array.items, expected),
        else => false,
    };
}

fn jsonArrayEqual(left: []const std.json.Value, right: []const std.json.Value) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value| {
        if (!jsonValueEqual(left_value, right_value)) return false;
    }
    return true;
}

fn jsonValueEqual(left: std.json.Value, right: std.json.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |value| value == right.bool,
        .integer => |value| value == right.integer,
        .float => |value| value == right.float,
        .number_string => |value| std.mem.eql(u8, value, right.number_string),
        .string => |value| std.mem.eql(u8, value, right.string),
        .array => |value| jsonArrayEqual(value.items, right.array.items),
        .object => |value| {
            if (value.count() != right.object.count()) return false;
            var iterator = value.iterator();
            while (iterator.next()) |entry| {
                const right_value = right.object.get(entry.key_ptr.*) orelse return false;
                if (!jsonValueEqual(entry.value_ptr.*, right_value)) return false;
            }
            return true;
        },
    };
}

test "legacy result adapter distinguishes an array node from a nodelist" {
    const allocator = std.testing.allocator;
    var actual_array = std.json.Array.init(allocator);
    defer actual_array.deinit();
    try actual_array.append(.{ .integer = 1 });
    try actual_array.append(.{ .integer = 2 });
    const actual = std.json.Value{ .array = actual_array };

    var expected_array = std.json.Array.init(allocator);
    defer expected_array.deinit();
    try expected_array.append(.{ .integer = 1 });
    try expected_array.append(.{ .integer = 2 });

    try std.testing.expect(matchesNodelist(actual, &.{.{ .array = expected_array }}));
    try std.testing.expect(matchesNodelist(actual, &.{ .{ .integer = 1 }, .{ .integer = 2 } }));
}

test "alternative results preserve order" {
    var actual_array = std.json.Array.init(std.testing.allocator);
    defer actual_array.deinit();
    try actual_array.append(.{ .string = "B" });
    try actual_array.append(.{ .string = "A" });

    const alternatives = [_][]const std.json.Value{
        &.{ .{ .string = "A" }, .{ .string = "B" } },
        &.{ .{ .string = "B" }, .{ .string = "A" } },
    };
    const test_case: TestCase = .{
        .name = "alternative order",
        .selector = "$.*",
        .results = &alternatives,
    };

    try std.testing.expect(matchesExpected(.{ .array = actual_array }, test_case));
}
