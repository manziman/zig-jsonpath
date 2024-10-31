//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
//! The following implements the IETF RFC 9535 JSONPath specification.
//!
//!    +==================+================================================+
//!   | Syntax Element   | Description                                    |
//!   +==================+================================================+
//!   | $                | root node identifier (Section 2.2)             |
//!   +------------------+------------------------------------------------+
//!   | @                | current node identifier (Section 2.3.5)        |
//!   |                  | (valid only within filter selectors)           |
//!   +------------------+------------------------------------------------+
//!   | [<selectors>]    | child segment (Section 2.5.1): selects         |
//!   |                  | zero or more children of a node                |
//!   +------------------+------------------------------------------------+
//!   | .name            | shorthand for ['name']                         |
//!   +------------------+------------------------------------------------+
//!   | .*               | shorthand for [*]                              |
//!   +------------------+------------------------------------------------+
//!   | ..[<selectors>]  | descendant segment (Section 2.5.2):            |
//!   |                  | selects zero or more descendants of a node     |
//!   +------------------+------------------------------------------------+
//!   | ..name           | shorthand for ..['name']                       |
//!   +------------------+------------------------------------------------+
//!   | ..*              | shorthand for ..[*]                            |
//!   +------------------+------------------------------------------------+
//!   | 'name'           | name selector (Section 2.3.1): selects a       |
//!   |                  | named child of an object                       |
//!   +------------------+------------------------------------------------+
//!   | *                | wildcard selector (Section 2.3.2): selects     |
//!   |                  | all children of a node                         |
//!   +------------------+------------------------------------------------+
//!   | 3                | index selector (Section 2.3.3): selects an     |
//!   |                  | indexed child of an array (from 0)             |
//!   +------------------+------------------------------------------------+
//!   | 0:100:5          | array slice selector (Section 2.3.4):          |
//!   |                  | start:end:step for arrays                      |
//!   +------------------+------------------------------------------------+
//!   | ?<logical-expr>  | filter selector (Section 2.3.5): selects       |
//!   |                  | particular children using a logical            |
//!   |                  | expression                                     |
//!   +------------------+------------------------------------------------+
//!   | length(@.foo)    | function extension (Section 2.4): invokes      |
//!   |                  | a function in a filter expression              |
//!   +------------------+------------------------------------------------+
//!
//! Examples:
//!
//!    {
//!       "store": {
//!         "book": [
//!           { "category": "reference",
//!             "author": "Nigel Rees",
//!             "title": "Sayings of the Century",
//!             "price": 8.95
//!           },
//!           { "category": "fiction",
//!             "author": "Evelyn Waugh",
//!             "title": "Sword of Honour",
//!             "price": 12.99
//!           },
//!           { "category": "fiction",
//!             "author": "Herman Melville",
//!             "title": "Moby Dick",
//!             "isbn": "0-553-21311-3",
//!             "price": 8.99
//!         },
//!         { "category": "fiction",
//!           "author": "J. R. R. Tolkien",
//!           "title": "The Lord of the Rings",
//!           "isbn": "0-395-19395-8",
//!           "price": 22.99
//!         }
//!       ],
//!       "bicycle": {
//!         "color": "red",
//!         "price": 399
//!       }
//!     }
//!   }
//!     +========================+=======================================+
//!    | JSONPath               | Intended Result                       |
//!    +========================+=======================================+
//!    | $.store.book[*].author | the authors of all books in the store |
//!    +------------------------+---------------------------------------+
//!    | $..author              | all authors                           |
//!    +------------------------+---------------------------------------+
//!    | $.store.*              | all things in the store, which are    |
//!    |                        | some books and a red bicycle          |
//!    +------------------------+---------------------------------------+
//!    | $.store..price         | the prices of everything in the store |
//!    +------------------------+---------------------------------------+
//!    | $..book[2]             | the third book                        |
//!    +------------------------+---------------------------------------+
//!    | $..book[2].author      | the third book's author               |
//!    +------------------------+---------------------------------------+
//!    | $..book[2].publisher   | empty result: the third book does not |
//!    |                        | have a "publisher" member             |
//!    +------------------------+---------------------------------------+
//!    | $..book[-1]            | the last book in order                |
//!    +------------------------+---------------------------------------+
//!    | $..book[0,1]           | the first two books                   |
//!    | $..book[:2]            |                                       |
//!    +------------------------+---------------------------------------+
//!    | $..book[?@.isbn]       | all books with an ISBN number         |
//!    +------------------------+---------------------------------------+
//!    | $..book[?@.price<10]   | all books cheaper than 10             |
//!    +------------------------+---------------------------------------+
//!    | $..*                   | all member values and array elements  |
//!    |                        | contained in the input value          |
//!    +------------------------+---------------------------------------+
//! Evaluate a JSONPath expression
//!
//! It works like a sort of state machine. We always start at the "root" node (even when it isn't the actual root, it's the top level of the value we are passed)
//!
//! Node -> Either a '.' (indicating that we should try to go to the next node identified by the key)
//!        -> Or a '[' (indicating that we should evaluate a selector - producing an array or nodes instead of a single node). This will trigger n recursive calls to the function, where n is the number of items in the array selected by the selector
//!
//!
//! The '.' case is straightforward. We read the key, and then continue evaluation from the next part of the path.
//! If we hit '.' again, then we will evaluate all keys in the current node in the same way that we would handle a selector expression
const std = @import("std");
const zbench = @import("zbench");
const json = std.json;
const print = std.log.debug;
const testing = std.testing;

// Extend this type with the OutOfMemory error from std.mem
pub const JsonPathError = error{ InvalidPath, OutOfMemory, NotFound, Unimplemented, InvalidLogicalExpression };

const Operator = enum {
    Equals,
    NotEquals,
    GreaterThan,
    LessThan,
    GreaterThanOrEqualTo,
    LessThanOrEqualTo,
    And,
    Or,
    Not,
    Unset,
};

// Struct to contain either a primitive value or an operator
const LogicalExpressionComponent = union(enum) {
    value: json.Value, // Either a string or a number
    operator: Operator,
};

// Compare values that could be integers or floats
fn compareNumericValues(left: *json.Value, right: *json.Value, operator: *Operator) JsonPathError!bool {
    // Convert both values to float
    const left_float = switch (left.*) {
        .integer => @as(f64, @floatFromInt(left.integer)),
        .float => left.float,
        else => return JsonPathError.InvalidLogicalExpression,
    };
    const right_float = switch (right.*) {
        .integer => @as(f64, @floatFromInt(right.integer)),
        .float => right.float,
        else => return JsonPathError.InvalidLogicalExpression,
    };
    switch (operator.*) {
        .Equals => return left_float == right_float,
        .NotEquals => return left_float != right_float,
        .GreaterThan => return left_float > right_float,
        .LessThan => return left_float < right_float,
        .GreaterThanOrEqualTo => return left_float >= right_float,
        .LessThanOrEqualTo => return left_float <= right_float,
        else => return JsonPathError.InvalidLogicalExpression,
    }
}

// Compare strings lexicographically
fn compareStringValues(left: []const u8, right: []const u8, operator: *Operator) JsonPathError!bool {
    // For equals or not equals, use std.mem.eql
    switch (operator.*) {
        .Equals => return std.mem.eql(u8, left, right),
        .NotEquals => return !std.mem.eql(u8, left, right),
        else => {},
    }
    var index: u64 = 0;
    while (index < left.len and index < right.len) {
        if (left[index] == right[index]) {
            index += 1;
            continue;
        }
        switch (operator.*) {
            .GreaterThan => return left[index] > right[index],
            .LessThan => return left[index] < right[index],
            else => return JsonPathError.InvalidLogicalExpression,
        }
        index += 1;
    }
    // If we get here, then the strings are equal up to the length of the shorter string
    switch (operator.*) {
        .GreaterThan => return left.len > right.len,
        .LessThan => return left.len < right.len,
        else => return false,
    }
}

fn compareBooleanValues(left: *json.Value, right: *json.Value, operator: *Operator) JsonPathError!bool {
    switch (operator.*) {
        .Equals => return left.bool == right.bool,
        .NotEquals => return left.bool != right.bool,
        .And => return left.bool and right.bool,
        .Or => return left.bool or right.bool,
        else => return JsonPathError.InvalidLogicalExpression,
    }
}

// Generic function to compare two values using an operator
fn compareTwoValues(left: *json.Value, right: *json.Value, operator: *Operator) JsonPathError!bool {
    switch (left.*) {
        .integer, .float => {
            switch (right.*) {
                .integer, .float => return compareNumericValues(left, right, operator),
                else => return JsonPathError.InvalidLogicalExpression,
            }
        },
        .bool => {
            switch (right.*) {
                .bool => return compareBooleanValues(left, right, operator),
                else => return JsonPathError.InvalidLogicalExpression,
            }
        },
        .string => {
            switch (right.*) {
                .string => return compareStringValues(left.string, right.string, operator),
                else => return JsonPathError.InvalidLogicalExpression,
            }
        },
        else => return JsonPathError.InvalidLogicalExpression,
    }
}

fn evaluateLogicalExpression(allocator: std.mem.Allocator, expression: []LogicalExpressionComponent) JsonPathError!bool {
    const expression_str = try json.stringifyAlloc(allocator, expression, .{});
    print("evaluating logical expression: {s}\n", .{expression_str});
    // The expression must start with a primitive value, and primitive values must be followed by an operator
    if (expression.len == 0) {
        return JsonPathError.InvalidPath;
    }
    // Evaluate chain of operators and values
    // e.g. [{"value":"Nigel Rees"},{"operator":"Equals"},{"value":"Nigel Rees"},{"operator":"Or"},{"value":"Nigel Rees"},{"operator":"Equals"},{"value":"Herman Melville"}]
    var index: u64 = 0;
    var previous_value: *json.Value = undefined;
    var final_result: ?bool = undefined;
    var operator: Operator = .Unset;
    var and_or_operator: Operator = .Unset;
    var evaluating_chunk: bool = false;
    // For Or and And operations, we need to evaluate the expression in chunks.
    // Every timne we get either a Not followed by a value, or a value/operator/value, we evaluate that chunk of the expression.
    // These chunks can then be separated by Or/And operators. So if we then hit an And/Or operator, we store this in a variable and evaluate
    // the proceeding chunk. We then do a boolean comparison with the previous result and set that to the final result. This continues until
    // we hit the end of the expression.
    while (index < expression.len) {
        const item_str = try json.stringifyAlloc(allocator, &expression[index], .{});
        print("evaluating {s}\n", .{item_str});
        switch (expression[index]) {
            .value => {
                switch (operator) {
                    .Not => {
                        switch (expression[index].value) {
                            .bool => {
                                final_result = !expression[index].value.bool;
                            },
                            else => return JsonPathError.InvalidLogicalExpression,
                        }
                    },
                    .Unset => {
                        if (evaluating_chunk) {
                            return JsonPathError.InvalidPath;
                        }
                        print("setting previous value to {any}\n", .{expression[index].value});
                        previous_value = &expression[index].value;
                        evaluating_chunk = true;
                    },
                    else => {
                        const previous_value_str = try json.stringifyAlloc(allocator, previous_value, .{});
                        const compare_str = try json.stringifyAlloc(allocator, &expression[index].value, .{});
                        const operator_str = try json.stringifyAlloc(allocator, &operator, .{});
                        print("comparing {s} and {s} using operator {s}\n", .{ previous_value_str, compare_str, operator_str });
                        const new_result = try compareTwoValues(previous_value, &expression[index].value, &operator);
                        // If we have an And/Or operator, then we need to compare our new result with the previous result
                        if (and_or_operator != .Unset) {
                            print("setting final result to '{any} {any} {any}'\n", .{ final_result, and_or_operator, new_result });
                            final_result = switch (and_or_operator) {
                                .And => final_result.? and new_result,
                                .Or => final_result.? or new_result,
                                else => return JsonPathError.InvalidLogicalExpression,
                            };
                            and_or_operator = .Unset;
                        } else {
                            print("setting final result to {any}\n", .{new_result});
                            final_result = new_result;
                        }
                        print("chunk evaluated to {}\n", .{final_result.?});
                        evaluating_chunk = false;
                    },
                }
                operator = .Unset;
            },
            .operator => {
                print("evaluating operator: {any}\n", .{expression[index].operator});
                if (operator != .Unset) {
                    return JsonPathError.InvalidPath;
                }
                // Can only be And/Or if we already have a final result
                switch (expression[index].operator) {
                    .And, .Or => {
                        if (final_result == undefined) {
                            return JsonPathError.InvalidPath;
                        }
                        // If we're evaluating a chunk, then set the operator, otherwise set the and/or operator
                        if (evaluating_chunk) {
                            operator = expression[index].operator;
                        } else {
                            print("setting and/or operator to {any}\n", .{expression[index].operator});
                            and_or_operator = expression[index].operator;
                        }
                    },
                    else => {
                        operator = expression[index].operator;
                    },
                }
            },
        }
        index += 1;
    }
    if (final_result == undefined) {
        return JsonPathError.InvalidPath;
    }
    return final_result.?;
}

fn evaluateLogicalExpressionSelector(allocator: std.mem.Allocator, expression: []u8, value: *const json.Value) JsonPathError!bool {
    // We're going to parse the expression into a series of primitive values and operators, then evaluate it
    // @ refers to the root value
    print("evaluating expression: {s}\n", .{expression});
    var logical_expressions = std.ArrayList(LogicalExpressionComponent).init(allocator);
    var expression_index: u64 = 0;
    ex: while (expression_index < expression.len) {
        const char = expression[expression_index];
        switch (char) {
            // Here we expect to find a primitive value using a JSON string expression. Parse the expression until we hit an operator
            '(' => {
                // Grouping expression. Read until we hit a closing ')' and then recursively call evaluateLogicalExpressionSelector
                expression_index += 1;
                const group_expression_start = expression_index;
                var grouping_depth: u64 = 1;
                while (expression_index < expression.len) {
                    if (expression[expression_index] == '(') {
                        grouping_depth += 1;
                    } else if (expression[expression_index] == ')') {
                        grouping_depth -= 1;
                        if (grouping_depth == 0) {
                            break;
                        }
                    }
                    expression_index += 1;
                }
                if (expression_index >= expression.len) {
                    return JsonPathError.InvalidPath;
                }
                print("evaluating group expression: {s}\n", .{expression[group_expression_start..expression_index]});
                const evaluated_value = try evaluateLogicalExpressionSelector(allocator, expression[group_expression_start..expression_index], value);
                logical_expressions.append(.{ .value = json.Value{ .bool = evaluated_value } }) catch return JsonPathError.OutOfMemory;
                expression_index += 1;
                continue :ex;
            },
            '@' => {
                expression_index += 1;
                const expression_start_index = expression_index;
                while (expression_index < expression.len and expression[expression_index] != '=' and expression[expression_index] != '!' and expression[expression_index] != '>' and expression[expression_index] != '<' and expression[expression_index] != ' ') {
                    expression_index += 1;
                }
                const expression_end_index = expression_index;
                const expression_slice = expression[expression_start_index..expression_end_index];
                print("evaluating json string in logical expression: {s}\n", .{expression_slice});
                // Call evaluateJsonPath with the expression slice and the root value
                const evaluated_value = try evaluateJsonPath(allocator, expression_slice, value, .{ .skip_root = true });
                // If the evaluated value is null, then return false
                if (evaluated_value == null) {
                    return false;
                }
                logical_expressions.append(.{ .value = evaluated_value.? }) catch return JsonPathError.OutOfMemory;
                continue :ex;
            },
            '=' => {
                expression_index += 1;
                // Next character must be =
                if (expression_index >= expression.len or expression[expression_index] != '=') {
                    return JsonPathError.InvalidPath;
                }
                expression_index += 1;
                print("evaluating equals operator\n", .{});
                logical_expressions.append(.{ .operator = .Equals }) catch return JsonPathError.OutOfMemory;
                continue :ex;
            },
            '!' => {
                // This can be !, !=
                expression_index += 1;
                if (expression_index >= expression.len) {
                    return JsonPathError.InvalidPath;
                }
                if (expression[expression_index] == '=') {
                    expression_index += 1;
                    print("evaluating not equals operator\n", .{});
                    logical_expressions.append(.{ .operator = .NotEquals }) catch return JsonPathError.OutOfMemory;
                    continue :ex;
                }
                return JsonPathError.InvalidPath;
            },
            '&' => { // &&
                // Next character must be &
                expression_index += 1;
                if (expression_index >= expression.len) {
                    return JsonPathError.InvalidPath;
                }
                if (expression[expression_index] != '&') {
                    return JsonPathError.InvalidPath;
                }
                expression_index += 1;
                print("evaluating and operator\n", .{});
                logical_expressions.append(.{ .operator = .And }) catch return JsonPathError.OutOfMemory;
                continue :ex;
            },
            '|' => { // ||
                expression_index += 1;
                if (expression_index >= expression.len) {
                    return JsonPathError.InvalidPath;
                }
                if (expression[expression_index] != '|') {
                    return JsonPathError.InvalidPath;
                }
                expression_index += 1;
                print("evaluating or operator\n", .{});
                logical_expressions.append(.{ .operator = .Or }) catch return JsonPathError.OutOfMemory;
                continue :ex;
            },
            '>' => {
                expression_index += 1;
                if (expression_index >= expression.len) {
                    return JsonPathError.InvalidPath;
                }
                if (expression[expression_index] == '=') {
                    expression_index += 1;
                    print("evaluating greater than or equal to operator\n", .{});
                    logical_expressions.append(.{ .operator = .GreaterThanOrEqualTo }) catch return JsonPathError.OutOfMemory;
                } else {
                    print("evaluating greater than operator\n", .{});
                    logical_expressions.append(.{ .operator = .GreaterThan }) catch return JsonPathError.OutOfMemory;
                }
                continue :ex;
            },
            '<' => {
                expression_index += 1;
                if (expression_index >= expression.len) {
                    return JsonPathError.InvalidPath;
                }
                if (expression[expression_index] == '=') {
                    expression_index += 1;
                    print("evaluating less than or equal to operator\n", .{});
                    logical_expressions.append(.{ .operator = .LessThanOrEqualTo }) catch return JsonPathError.OutOfMemory;
                } else {
                    print("evaluating less than operator\n", .{});
                    logical_expressions.append(.{ .operator = .LessThan }) catch return JsonPathError.OutOfMemory;
                }
                continue :ex;
            },
            ' ' => {
                expression_index += 1;
                continue :ex;
            },
            '\'' => {
                // We are parsing a quoted string
                expression_index += 1;
                if (expression_index >= expression.len) {
                    return JsonPathError.InvalidPath;
                }
                var expr_char = expression[expression_index];
                var escape_next_char: bool = false;
                var string_buffer = std.ArrayList(u8).init(allocator);
                while (expression_index < expression.len and (expr_char != '\'' or escape_next_char)) {
                    switch (expr_char) {
                        '\\' => {
                            escape_next_char = true;
                            expression_index += 1;
                            if (expression_index < expression.len) {
                                expr_char = expression[expression_index];
                            }
                            continue :ex;
                        },
                        else => {},
                    }
                    string_buffer.append(expr_char) catch return JsonPathError.OutOfMemory;
                    expression_index += 1;
                    if (expression_index < expression.len) {
                        expr_char = expression[expression_index];
                    }
                }
                // Final character must be a '
                if (expr_char != '\'') {
                    return JsonPathError.InvalidPath;
                }
                expression_index += 1;
                print("evaluating quoted string, string: {s}\n", .{string_buffer.items});
                logical_expressions.append(.{ .value = json.Value{ .string = string_buffer.items } }) catch return JsonPathError.OutOfMemory;
                continue :ex;
            },
            '0'...'9', '-' => {
                // We are parsing a number
                const expression_start_index = expression_index;
                var expr_char = expression[expression_index];
                var number_buffer = std.ArrayList(u8).init(allocator);
                var is_float: bool = false;
                while (expression_index < expression.len) {
                    switch (expr_char) {
                        '0'...'9' => {},
                        '.' => {
                            if (expression_start_index == expression_index or is_float) {
                                return JsonPathError.InvalidPath;
                            }
                            is_float = true;
                        },
                        '-' => {
                            if (expression_start_index != expression_index) {
                                return JsonPathError.InvalidPath;
                            }
                        },
                        else => break,
                    }
                    number_buffer.append(expr_char) catch return JsonPathError.OutOfMemory;
                    expression_index += 1;
                    if (expression_index < expression.len) {
                        expr_char = expression[expression_index];
                    }
                }
                print("evaluating number, number: {s}\n", .{number_buffer.items});
                logical_expressions.append(.{ .value = json.Value.parseFromNumberSlice(number_buffer.items) }) catch return JsonPathError.OutOfMemory;
                continue :ex;
            },
            't' => { // could be true
                expression_index += 1;
                // Check if the following characters are true
                if (expression_index + 3 < expression.len and expression[expression_index] == 'r' and expression[expression_index + 1] == 'u' and expression[expression_index + 2] == 'e') {
                    expression_index += 3;
                    print("evaluating true\n", .{});
                    logical_expressions.append(.{ .value = json.Value{ .bool = true } }) catch return JsonPathError.OutOfMemory;
                    continue :ex;
                }
                return JsonPathError.InvalidPath;
            },
            'f' => { // could be false
                expression_index += 1;
                // Check if the following characters are false
                if (expression_index + 4 < expression.len and expression[expression_index] == 'a' and expression[expression_index + 1] == 'l' and expression[expression_index + 2] == 's' and expression[expression_index + 3] == 'e') {
                    expression_index += 4;
                    print("evaluating false\n", .{});
                    logical_expressions.append(.{ .value = json.Value{ .bool = false } }) catch return JsonPathError.OutOfMemory;
                    continue :ex;
                }
            },
            else => return JsonPathError.InvalidPath,
        }
    }
    // Evaluate the logical expressions
    return try evaluateLogicalExpression(allocator, logical_expressions.items);
}

const books_json =
    \\[
    \\   { "category": "reference",
    \\     "author": "Nigel Rees",
    \\     "title": "Sayings of the Century",
    \\     "price": 8.95
    \\   },
    \\   { "category": "fiction",
    \\     "author": "Evelyn Waugh",
    \\     "title": "Sword of Honour",
    \\     "isbn": "0-553-21311-3",
    \\     "price": 12.99
    \\   },
    \\   { "category": "fiction",
    \\     "author": "Herman Melville",
    \\     "title": "Moby Dick",
    \\     "isbn": "0-553-21311-3",
    \\     "price": 8.99
    \\   },
    \\   { "category": "fiction",
    \\     "author": "J. R. R. Tolkien",
    \\     "title": "The Lord of the Rings",
    \\     "isbn": "0-395-19395-8",
    \\     "price": 22.99
    \\   }
    \\]
;

test "basic logical expression (string comparison)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Use book store JSON, find books by author
    var root_json: json.Parsed(json.Value) = undefined;
    root_json = try json.parseFromSlice(json.Value, alloc, books_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("@.author == 'J. R. R. Tolkien'");
    // Loop through the root json and evaluate the path for each item
    // Only the last item should match
    var index: u64 = 0;
    for (root_json.value.array.items) |item| {
        const item_str = try json.stringifyAlloc(alloc, item, .{});
        print("Item: {s}\n", .{item_str});
        const result = try evaluateLogicalExpressionSelector(alloc, path.items, &item);
        // stringify result, compare to expected
        const result_str = try json.stringifyAlloc(alloc, result, .{});
        print("Result: {s}\n", .{result_str});
        // Should only be true for the last item
        switch (index) {
            0 => try testing.expect(std.mem.eql(u8, "false", result_str)),
            1 => try testing.expect(std.mem.eql(u8, "false", result_str)),
            2 => try testing.expect(std.mem.eql(u8, "false", result_str)),
            3 => try testing.expect(std.mem.eql(u8, "true", result_str)),
            else => return JsonPathError.InvalidPath,
        }
        index += 1;
    }
}

test "basic logical expression (float comparison)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Parsed(json.Value) = undefined;
    root_json = try json.parseFromSlice(json.Value, alloc, books_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("@.price > 8.99");
    var index: u64 = 0;
    for (root_json.value.array.items) |item| {
        const result = try evaluateLogicalExpressionSelector(alloc, path.items, &item);
        const result_str = try json.stringifyAlloc(alloc, result, .{});
        print("Result: {s}\n", .{result_str});
        switch (index) {
            0 => try testing.expect(std.mem.eql(u8, "false", result_str)),
            1 => try testing.expect(std.mem.eql(u8, "true", result_str)),
            2 => try testing.expect(std.mem.eql(u8, "false", result_str)),
            3 => try testing.expect(std.mem.eql(u8, "true", result_str)),
            else => return JsonPathError.InvalidPath,
        }
        index += 1;
    }
}

const SelectorType = enum {
    Slice,
    Pick,
    All,
    Expression,
    Unknown,
};

pub fn evaluateJsonPath(allocator: std.mem.Allocator, path: []u8, value: *const json.Value, opts: struct { skip_root: bool = false, start_index: u64 = 0 }) JsonPathError!?json.Value {
    print("Evaluating path: '{s}'\n", .{path});
    const value_str = try json.stringifyAlloc(allocator, value.*, .{});
    print("Value: {s}\n", .{value_str});
    // Check for empty string
    if (!opts.skip_root and path.len == 0) {
        return JsonPathError.InvalidPath;
    }
    var path_index: u64 = 0;
    // If we are not skipping the root, check that the path is valid (starts with $)
    if (!opts.skip_root) {
        if (path[0] != '$') {
            return JsonPathError.InvalidPath;
        }
        path_index += 1;
        if (path.len == 1 or (path.len == 2 and path[1] == '.')) {
            return value.*;
        }
    }
    var current_node: *const json.Value = value;
    // var previous_node: *const json.Value = undefined;
    // Buffer to contain the current node name
    var node_name_buffer = std.ArrayList(u8).init(allocator);
    // Loop through the path string
    var char: u8 = undefined;
    // We start at a node each iteration
    ev: while (path_index < path.len) {
        char = path[path_index];
        switch (char) {
            // Case 1: We are going to try to select a single next node base on the proceeding key
            '.' => {
                // Error if not an object
                if (current_node.* != .object) {
                    return undefined;
                }
                // Read the key for the next node (exit loop if ., [, ], or *)
                path_index += 1;
                if (path_index >= path.len) {
                    return JsonPathError.InvalidPath;
                }
                char = path[path_index];
                // '..' - evaluate all keys in the current node
                if (char == '.') {
                    print("Evaluating all keys in current node\n", .{});
                    // If current node is not an object, then return undefined
                    if (current_node.* != .object) {
                        print("Current node is not an object\n", .{});
                        return undefined;
                    }
                    // Loop through all of the keys in the current node and evaluate the path for each key
                    // Create a new ArrayList to contain the evaluated keys
                    var evaluated_keys = std.ArrayList(json.Value).init(allocator);
                    for (current_node.object.keys()) |key| {
                        print("Evaluating key: {s}\n", .{key});
                        const evaluated_key = try evaluateJsonPath(allocator, path[path_index..], &current_node.object.get(key).?, .{ .skip_root = true });
                        evaluated_keys.append(evaluated_key.?) catch return JsonPathError.OutOfMemory;
                    }
                    return json.Value{ .array = evaluated_keys };
                }
                while (char != '.' and char != '[' and char != ']' and char != '*' and path_index < path.len) {
                    node_name_buffer.append(char) catch return JsonPathError.OutOfMemory;
                    path_index += 1;
                    if (path_index < path.len) {
                        char = path[path_index];
                    }
                }
                // Invalid path if we have an empty name buffer
                if (node_name_buffer.items.len == 0) {
                    return JsonPathError.InvalidPath;
                }
                print("Evaluating next node: {s}\n", .{node_name_buffer.items});
                // Try to get the next node using the key in the node_name_buffer
                const next_node = current_node.object.getPtr(node_name_buffer.items);
                if (next_node == null) {
                    print("Next node is null\n", .{});
                    return undefined;
                }
                current_node = next_node.?;
                print("Next node: {any}\n", .{current_node});
                // Clear node_name_buffer
                node_name_buffer.clearRetainingCapacity();
            },
            '[' => {
                print("Evaluating selector, char: {c}\n", .{char});
                path_index += 1;
                if (path_index >= path.len) {
                    return JsonPathError.InvalidPath;
                }
                char = path[path_index];
                // If the next character is a ', we are trying to get a node at the proceeding key, so read characters until we hit another '
                if (char == '\'') {
                    print("Evaluating quoted node name\n", .{});
                    path_index += 1;
                    char = path[path_index];
                    // Read characters until we hit another '
                    var escape_next_char: bool = false;
                    while (path_index < path.len and (char != '\'' or escape_next_char)) {
                        node_name_buffer.append(char) catch return JsonPathError.OutOfMemory;
                        path_index += 1;
                        if (path_index < path.len) {
                            char = path[path_index];
                            if (char == '\\') {
                                escape_next_char = true;
                                path_index += 1;
                                if (path_index < path.len) {
                                    char = path[path_index];
                                }
                            } else {
                                escape_next_char = false;
                            }
                        }
                    }
                    // If we hit the end of the path without finding another ', then return invalid path
                    if (path_index >= path.len) {
                        return JsonPathError.InvalidPath;
                    }
                    path_index += 1;
                    // If the next character is not a ']', then return invalid path
                    if (path_index >= path.len) {
                        return JsonPathError.InvalidPath;
                    }
                    char = path[path_index];
                    if (char != ']') {
                        return JsonPathError.InvalidPath;
                    }
                    print("Getting next node, node name buffer: {s}\n", .{node_name_buffer.items});
                    // Get the next node
                    const next_node = current_node.object.getPtr(node_name_buffer.items);
                    if (next_node == null) {
                        print("Next node is null\n", .{});
                        return undefined;
                    }
                    current_node = next_node.?;
                    print("Next node: {any}\n", .{current_node});
                    path_index += 1;
                    continue :ev;
                }
                // First check if the current node is even an array. If it isn't, then we will return undefined
                if (current_node.* != .array) {
                    return undefined;
                }
                var selector_type: SelectorType = .Unknown;
                const selector_expression_start_index = path_index;
                // Read through the entire selector expression (until we hit a ])
                while (char != ']' and path_index < path.len) {
                    // We use the character to determine the selector type
                    switch (char) {
                        '*' => {
                            if (selector_type != .Unknown) {
                                return JsonPathError.InvalidPath;
                            }
                            print("Setting selector type to All\n", .{});
                            selector_type = .All;
                        },
                        ':' => {
                            if (selector_type != .Unknown and selector_type != .Slice) {
                                return JsonPathError.InvalidPath;
                            }
                            print("Setting selector type to Slice\n", .{});
                            selector_type = .Slice;
                        },
                        ',' => {
                            if (selector_type != .Unknown and selector_type != .Pick) {
                                return JsonPathError.InvalidPath;
                            }
                            print("Setting selector type to Pick\n", .{});
                            selector_type = .Pick;
                        },
                        else => {
                            // If the first character is a ?, then we are evaluating an expression
                            if (char == '?' and path_index == selector_expression_start_index) {
                                print("Setting selector type to Expression\n", .{});
                                selector_type = .Expression;
                            }
                        },
                    }
                    path_index += 1;
                    if (path_index < path.len) {
                        char = path[path_index];
                    }
                }
                const selector_expression_end_index = path_index;
                // If the expression is empty, then return invalid path
                if (selector_expression_start_index == selector_expression_end_index) {
                    return JsonPathError.InvalidPath;
                }
                // Print the character at the end index
                print("Selector expression end char: {c}\n", .{path[selector_expression_end_index]});
                // The default is pick
                if (selector_type == .Unknown) {
                    selector_type = .Pick;
                }
                // Evaluate the selector expression
                // We're going to be populating an ArrayList with the evaluated selector expression
                var sliced_array = std.ArrayList(json.Value).init(allocator);
                switch (selector_type) {
                    .Slice => {
                        // Read through the expression, getting a start, end, and step
                        // If the step is not defined, then it is 1
                        // If the start is not defined, then it is 0
                        // If the end is not defined, then it is the length of the array
                        // We populate the ArrayList with recursive calls to evaluateJsonPath using the values selected by the slice
                        var start: u64 = 0;
                        var end: u64 = current_node.array.items.len;
                        var step: u64 = 1;
                        var start_end_step: u2 = 0; // 0 = start, 1 = end, 2 = step
                        var selector_expression_index: u64 = selector_expression_start_index;
                        var selector_expression_char: u8 = undefined;
                        var parse_int_buffer = std.ArrayList(u8).init(allocator);
                        selector_expression_char = path[selector_expression_index];
                        while (selector_expression_index < selector_expression_end_index) {
                            switch (selector_expression_char) {
                                // 0-9 and - get read into parse_int_buffer
                                '-', '0'...'9' => {
                                    parse_int_buffer.append(selector_expression_char) catch return JsonPathError.OutOfMemory;
                                },
                                ':' => {
                                    // If there are characters in the parse_int_buffer, then parse them as an integer
                                    if (parse_int_buffer.items.len > 0) {
                                        const parsed_int = std.fmt.parseInt(u64, parse_int_buffer.items, 10) catch return JsonPathError.InvalidPath;
                                        switch (start_end_step) {
                                            0 => start = parsed_int,
                                            1 => end = parsed_int,
                                            2 => step = parsed_int,
                                            else => {
                                                return JsonPathError.InvalidPath;
                                            },
                                        }
                                    }
                                    start_end_step += 1;
                                    if (start_end_step > 2) {
                                        return JsonPathError.InvalidPath;
                                    }
                                    parse_int_buffer.clearRetainingCapacity();
                                },
                                else => {
                                    return JsonPathError.InvalidPath;
                                },
                            }
                            selector_expression_index += 1;
                            if (selector_expression_index < selector_expression_end_index) {
                                selector_expression_char = path[selector_expression_index];
                            } else if (parse_int_buffer.items.len > 0) {
                                const parsed_int = std.fmt.parseInt(u64, parse_int_buffer.items, 10) catch return JsonPathError.InvalidPath;
                                switch (start_end_step) {
                                    0 => start = parsed_int,
                                    1 => end = parsed_int,
                                    2 => step = parsed_int,
                                    else => {
                                        return JsonPathError.InvalidPath;
                                    },
                                }
                            }
                        }
                        // If there are characters in the parse_int_buffer, then parse them
                        // Slice array
                        // If the start is greater than the end, then return undefined
                        // If the start is greater than the length of the array, then return undefined
                        if (start > end or start > current_node.array.items.len) {
                            return undefined;
                        }
                        // If the end is greater than the length of the array, then set it to the length of the array
                        if (end > current_node.array.items.len) {
                            end = current_node.array.items.len;
                        }
                        // If the step is 0, then return invalid path
                        if (step == 0) {
                            return JsonPathError.InvalidPath;
                        }
                        // If the step is negative, then iterate backwards through the array
                        // If the step is positive, then iterate forwards through the array
                        print("Slicing array, start: {d}, end: {d}, step: {d}\n", .{ start, end, step });
                        path_index += 1;
                        while (start < end) : (start += step) {
                            // Otherwise, we need to evaluate the rest of the path
                            const evaluated_item = try evaluateJsonPath(allocator, path[path_index..], &current_node.array.items[start], .{ .skip_root = true });
                            sliced_array.append(evaluated_item.?) catch return JsonPathError.OutOfMemory;
                        }
                        return json.Value{ .array = sliced_array };
                    },
                    .Pick => {
                        print("Picking items: {s}\n", .{path[selector_expression_start_index..selector_expression_end_index]});
                        // Loop through the pick list and add the corresponding items to the array
                        var pick_items = std.ArrayList(u64).init(allocator);
                        var selector_expression_index: u64 = selector_expression_start_index;
                        var selector_expression_char: u8 = undefined;
                        var parse_int_buffer = std.ArrayList(u8).init(allocator);
                        selector_expression_char = path[selector_expression_index];
                        while (selector_expression_index < selector_expression_end_index) {
                            switch (selector_expression_char) {
                                '-', '0'...'9' => {
                                    parse_int_buffer.append(selector_expression_char) catch return JsonPathError.OutOfMemory;
                                },
                                ',' => {
                                    if (parse_int_buffer.items.len > 0) {
                                        const parsed_int = std.fmt.parseInt(u64, parse_int_buffer.items, 10) catch return JsonPathError.InvalidPath;
                                        pick_items.append(parsed_int) catch return JsonPathError.OutOfMemory;
                                    } else {
                                        return JsonPathError.InvalidPath;
                                    }
                                },
                                else => {
                                    return JsonPathError.InvalidPath;
                                },
                            }
                            selector_expression_index += 1;
                            if (selector_expression_index < selector_expression_end_index) {
                                selector_expression_char = path[selector_expression_index];
                            } else if (parse_int_buffer.items.len > 0) {
                                const parsed_int = std.fmt.parseInt(u64, parse_int_buffer.items, 10) catch return JsonPathError.InvalidPath;
                                pick_items.append(parsed_int) catch return JsonPathError.OutOfMemory;
                            }
                        }
                        // Loop through the pick list and add the corresponding items to the array
                        path_index += 1;
                        for (pick_items.items) |index| {
                            const evaluated_item = try evaluateJsonPath(allocator, path[path_index..], &current_node.array.items[index], .{ .skip_root = true });
                            sliced_array.append(evaluated_item.?) catch return JsonPathError.OutOfMemory;
                        }
                        return json.Value{ .array = sliced_array };
                    },
                    .Expression => {
                        // Evaluate the expression
                        // Go through each item in the array and evaluate the expression
                        // If the expression is true for any item, then add it to the array
                        // Return the array
                        const node_string = try json.stringifyAlloc(allocator, current_node, .{});
                        print("evaluating expression: {s} on node: {s}\n", .{ path[selector_expression_start_index..selector_expression_end_index], node_string });
                        for (current_node.array.items) |item| {
                            const filter_match = try evaluateLogicalExpressionSelector(allocator, path[selector_expression_start_index + 1 .. selector_expression_end_index], &item);
                            if (filter_match) {
                                sliced_array.append(item) catch return JsonPathError.OutOfMemory;
                            }
                        }
                        return json.Value{ .array = sliced_array };
                    },
                    .All => {
                        // Loop through all of the items in the current node and evaluate the rest of the path
                        path_index += 1;
                        for (current_node.array.items) |item| {
                            const evaluated_item = try evaluateJsonPath(allocator, path[path_index..], &item, .{ .skip_root = true });
                            sliced_array.append(evaluated_item.?) catch return JsonPathError.OutOfMemory;
                        }
                        return json.Value{ .array = sliced_array };
                    },
                    else => {
                        return JsonPathError.InvalidPath;
                    },
                }
            },
            else => {
                return JsonPathError.InvalidPath;
            },
        }
    }
    // We're at the end of the evaluation. We will return the value at the current node
    print("Returning value at current node: {any}\n", .{current_node});
    return current_node.*;
}

const book_store_json =
    \\{
    \\    "store": {
    \\        "book": [
    \\            { "category": "reference",
    \\              "author": "Nigel Rees",
    \\              "title": "Sayings of the Century",
    \\              "price": 8.95,
    \\              "isbn": "0-553-21311-4"
    \\            },
    \\            { "category": "fiction",
    \\              "author": "Evelyn Waugh",
    \\              "title": "Sword of Honour",
    \\              "isbn": "0-553-21311-5",
    \\              "price": 12.99
    \\            },
    \\            { "category": "fiction",
    \\              "author": "Herman Melville",
    \\              "title": "Moby Dick",
    \\              "isbn": "0-553-21311-3",
    \\              "price": 8.99
    \\            },
    \\            { "category": "fiction",
    \\              "author": "J. R. R. Tolkien",
    \\              "title": "The Lord of the Rings",
    \\              "isbn": "0-395-19395-8",
    \\              "price": 22.99
    \\            }
    \\        ],
    \\       "bicycle": {
    \\         "color": "red",
    \\         "price": 399
    \\       }
    \\    }
    \\}
;

test "root query 2" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Parsed(json.Value) = undefined;
    root_json = try json.parseFromSlice(json.Value, alloc,
        \\{
        \\    "a": 1
        \\}
    , .{});
    // Initialize an ArrayList to contain the path string
    var path = std.ArrayList(u8).init(alloc);
    try path.append('$');
    const result = try evaluateJsonPath(alloc, path.items, &root_json.value, .{});
    try testing.expectEqualDeep(root_json.value, result.?);

    try path.append('.');
    const result2 = try evaluateJsonPath(alloc, path.items, &root_json.value, .{});
    try testing.expectEqualDeep(root_json.value, result2.?);
}

test "basic jsonpath 2" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Parsed(json.Value) = undefined;
    root_json = try json.parseFromSlice(json.Value, alloc,
        \\{
        \\    "a": {
        \\        "b": 3
        \\    }
        \\}
    , .{});
    const expected = json.Value{ .integer = 3 };
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.a.b");
    const result = try evaluateJsonPath(alloc, path.items, &root_json.value, .{});
    const result_string = json.stringifyAlloc(alloc, result.?, .{}) catch return;
    print("result: {s}\n", .{result_string});

    try testing.expectEqual(expected.integer, result.?.integer);
}

test "array of integers" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Parsed(json.Value) = undefined;
    root_json = try json.parseFromSlice(json.Value, alloc,
        \\[1, 2, 3, 4, 5]
    , .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$[1:3]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json.value, .{});
    const result_string = json.stringifyAlloc(alloc, result.?, .{}) catch return;
    print("result: {s}\n", .{result_string});
    try testing.expectEqual(result.?.array.items.len, 2);
    try testing.expectEqual(result.?.array.items[0].integer, 2);
    try testing.expectEqual(result.?.array.items[1].integer, 3);
}

test "basic slicing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Parsed(json.Value) = undefined;
    root_json = try json.parseFromSlice(json.Value, alloc, book_store_json, .{});
    var expected_json: json.Parsed(json.Value) = undefined;
    expected_json = try json.parseFromSlice(json.Value, alloc,
        \\[
        \\    {
        \\        "category": "fiction",
        \\        "author": "Evelyn Waugh",
        \\        "title": "Sword of Honour",
        \\        "isbn": "0-553-21311-5",
        \\        "price": 12.99
        \\    },
        \\    {
        \\        "category": "fiction",
        \\        "author": "Herman Melville",
        \\        "title": "Moby Dick",
        \\        "isbn": "0-553-21311-3",
        \\        "price": 8.99
        \\    }
        \\]
    , .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.book[1:3]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json.value, .{});
    const result_string = json.stringifyAlloc(alloc, result.?, .{}) catch return;
    print("result: {s}\n", .{result_string});
    try testing.expectEqual(expected_json.value.array.items.len, result.?.array.items.len);
    print("lengths match\n", .{});
    // Loop through the expected array and compare each item
    for (expected_json.value.array.items, 0..) |item, i| {
        // Get json printable string for both expected and result items
        const expected_string = try json.stringifyAlloc(alloc, &item, .{});
        const result_string2 = try json.stringifyAlloc(alloc, &result.?.array.items[i], .{});
        print("[{d}] expected: {s}, result: {s}\n", .{ i, expected_string, result_string2 });
        // Compare the two objects
        try testing.expectEqualDeep(item.object.get("author").?, result.?.array.items[i].object.get("author").?);
        try testing.expectEqualDeep(item.object.get("title").?, result.?.array.items[i].object.get("title").?);
        try testing.expectEqualDeep(item.object.get("isbn").?, result.?.array.items[i].object.get("isbn").?);
        try testing.expectEqualDeep(item.object.get("price").?, result.?.array.items[i].object.get("price").?);
    }
}

test "slicing and getting nested values from sliced array" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Parsed(json.Value) = undefined;
    root_json = try json.parseFromSlice(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.book[*].author");
    const result = try evaluateJsonPath(alloc, path.items, &root_json.value, .{});
    const result_string = json.stringifyAlloc(alloc, result.?, .{}) catch return;
    print("result: {s}\n", .{result_string});
    try testing.expectEqual(result.?.array.items.len, 4);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[0].string, "Nigel Rees"), true);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[1].string, "Evelyn Waugh"), true);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[2].string, "Herman Melville"), true);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[3].string, "J. R. R. Tolkien"), true);
}

test "using [''] syntax for selecting keys" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Parsed(json.Value) = undefined;
    root_json = try json.parseFromSlice(json.Value, alloc,
        \\{
        \\    "a": {
        \\        "b": 3
        \\    }
        \\}
    , .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.a['b']");
    const result = try evaluateJsonPath(alloc, path.items, &root_json.value, .{});
    try testing.expectEqual(result.?.integer, 3);
}

test "basic picking" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Parsed(json.Value) = undefined;
    root_json = try json.parseFromSlice(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.book[0,2]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json.value, .{});
    const result_string = json.stringifyAlloc(alloc, result.?, .{}) catch return;
    print("result: {s}\n", .{result_string});
    try testing.expectEqual(result.?.array.items.len, 2);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[0].object.get("author").?.string, "Nigel Rees"), true);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[1].object.get("author").?.string, "Herman Melville"), true);
}

test "basic expression selector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Parsed(json.Value) = undefined;
    root_json = try json.parseFromSlice(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.book[?@.price > 10]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json.value, .{});
    const result_string = json.stringifyAlloc(alloc, result.?, .{}) catch return;
    print("result: {s}\n", .{result_string});
    try testing.expectEqual(result.?.array.items.len, 2);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[0].object.get("author").?.string, "Evelyn Waugh"), true);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[1].object.get("author").?.string, "J. R. R. Tolkien"), true);
}

test "expression selector with nested groups" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Parsed(json.Value) = undefined;
    root_json = try json.parseFromSlice(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.book[?(@.price < 10) && ((@.category != 'fiction') && (@.author == 'Nigel Rees' || @.author == 'Herman Melville'))]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json.value, .{});
    const result_string = json.stringifyAlloc(alloc, result.?, .{}) catch return;
    print("result: {s}\n", .{result_string});
    try testing.expectEqual(result.?.array.items.len, 1);
    try testing.expectEqual(true, std.mem.eql(u8, result.?.array.items[0].object.get("isbn").?.string, "0-553-21311-4"));
}
