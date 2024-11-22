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
const printErr = std.log.err;
//const printWarn = std.log.warn;
const testing = std.testing;

// Extend this type with the OutOfMemory error from std.mem
pub const JsonPathError = error{
    InvalidPath, // Invalid path
    OutOfMemory, // Memory allocation failed
    InvalidLogicalExpression, // Invalid logical expression
    InvalidOperator, // Operator not supported for given types
    InvalidComparison, // Invalid comparison between types
    ComparisonTypeMismatch, // Comparison between different types
    BuiltinNotFound, // Builtin not found
    InvalidBuiltinFunctionArgument, // Invalid builtin argument
};

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
    value: ?json.Value, // Either a string or a number
    operator: Operator,
};

// The length() builtin expression function
// For strings, it returns the number of characters
// For arrays, it returns the number of elements
// For objects, it returns the number of keys
fn lengthBuiltin(value: *const json.Value) ?json.Value {
    switch (value.*) {
        .string => return json.Value{ .integer = @intCast(value.string.len) },
        .array => return json.Value{ .integer = @intCast(value.array.items.len) },
        .object => return json.Value{ .integer = @intCast(value.object.keys().len) },
        else => return null,
    }
}

// The count() builtin expression function
// Only for arrays
fn countBuiltin(value: *const json.Value) ?json.Value {
    if (value.* != .array) {
        return null;
    }
    return json.Value{ .integer = @intCast(value.array.items.len) };
}

// Given a JSON value, return a string name for the type of value it contains
fn valueTypeName(value: *const ?json.Value) []const u8 {
    if (value.* == null) {
        return "null";
    }
    return switch (value.*.?) {
        .bool => "boolean",
        .integer => "integer",
        .float => "float",
        .string => "string",
        .object => "object",
        .array => "array",
        .number_string => "number_string",
        else => unreachable,
    };
}

// Compare values that could be integers or floats
fn compareNumericValues(left: json.Value, right: json.Value, operator: *Operator) JsonPathError!bool {
    // Convert both values to float
    const left_float = switch (left) {
        .integer => @as(f64, @floatFromInt(left.integer)),
        .float => left.float,
        else => return JsonPathError.ComparisonTypeMismatch,
    };
    const right_float = switch (right) {
        .integer => @as(f64, @floatFromInt(right.integer)),
        .float => right.float,
        else => return JsonPathError.ComparisonTypeMismatch,
    };
    switch (operator.*) {
        .Equals => return left_float == right_float,
        .NotEquals => return left_float != right_float,
        .GreaterThan => return left_float > right_float,
        .LessThan => return left_float < right_float,
        .GreaterThanOrEqualTo => return left_float >= right_float,
        .LessThanOrEqualTo => return left_float <= right_float,
        else => return JsonPathError.InvalidComparison,
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
            else => return JsonPathError.InvalidComparison,
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

fn compareBooleanValues(left: json.Value, right: json.Value, operator: *Operator) JsonPathError!bool {
    switch (operator.*) {
        .Equals => return left.bool == right.bool,
        .NotEquals => return left.bool != right.bool,
        .And => return left.bool and right.bool,
        .Or => return left.bool or right.bool,
        else => return false,
    }
}

// Generic function to compare two values using an operator
fn compareTwoValues(left: *?json.Value, right: *?json.Value, operator: *Operator) JsonPathError!bool {
    // If either value is null, then the only case where the comparison is true is if the operator is Equals
    if (left.* == null or right.* == null) {
        switch (operator.*) {
            .Equals => return left.* == null and right.* == null,
            else => return false,
        }
    }
    switch (left.*.?) {
        .integer, .float => {
            switch (right.*.?) {
                .integer, .float => return compareNumericValues(left.*.?, right.*.?, operator),
                else => {
                    printErr("invalid logical expression: comparison between {s} and {s}\n", .{ valueTypeName(left), valueTypeName(right) });
                    return false;
                },
            }
        },
        .bool => {
            switch (right.*.?) {
                .bool => return compareBooleanValues(left.*.?, right.*.?, operator),
                else => return false,
            }
        },
        .string => {
            switch (right.*.?) {
                .string => return compareStringValues(left.*.?.string, right.*.?.string, operator),
                else => return false,
            }
        },
        else => return false,
    }
}

fn evaluateLogicalExpression(expression: []LogicalExpressionComponent) JsonPathError!bool {
    // The expression must start with a primitive value, and primitive values must be followed by an operator
    if (expression.len == 0) {
        printErr("invalid logical expression: empty expression\n", .{});
        return JsonPathError.InvalidPath;
    }
    // Evaluate chain of operators and values
    // e.g. [{"value":"Nigel Rees"},{"operator":"Equals"},{"value":"Nigel Rees"},{"operator":"Or"},{"value":"Nigel Rees"},{"operator":"Equals"},{"value":"Herman Melville"}]
    var index: u64 = 0;
    var previous_value: *?json.Value = undefined;
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
        switch (expression[index]) {
            .value => {
                switch (operator) {
                    .Not => {
                        switch (expression[index].value.?) {
                            .bool => {
                                final_result = !expression[index].value.?.bool;
                            },
                            else => {
                                printErr("invalid logical expression: ! operator must be followed by boolean\n", .{});
                                return JsonPathError.InvalidLogicalExpression;
                            },
                        }
                    },
                    .Unset => {
                        if (evaluating_chunk) {
                            printErr("invalid logical expression: value cannot follow another value\n", .{});
                            return JsonPathError.InvalidPath;
                        }
                        previous_value = &expression[index].value;
                        evaluating_chunk = true;
                    },
                    else => {
                        const new_result = try compareTwoValues(previous_value, &expression[index].value, &operator);
                        // If we have an And/Or operator, then we need to compare our new result with the previous result
                        if (and_or_operator != .Unset) {
                            final_result = switch (and_or_operator) {
                                .And => final_result.? and new_result,
                                .Or => final_result.? or new_result,
                                else => {
                                    printErr("invalid logical expression: unexpected and/or operator type: {any}\n", .{and_or_operator});
                                    return JsonPathError.InvalidLogicalExpression;
                                },
                            };
                            and_or_operator = .Unset;
                        } else {
                            final_result = new_result;
                        }
                        evaluating_chunk = false;
                    },
                }
                operator = .Unset;
            },
            .operator => {
                if (operator != .Unset) {
                    return JsonPathError.InvalidPath;
                }
                // Can only be And/Or if we already have a final result
                switch (expression[index].operator) {
                    .And, .Or => {
                        if (final_result == undefined) {
                            printErr("invalid logical expression: and/or operator must be preceded by a boolean or a value comparison\n", .{});
                            return JsonPathError.InvalidPath;
                        }
                        // If we're evaluating a chunk, then set the operator, otherwise set the and/or operator
                        if (evaluating_chunk) {
                            operator = expression[index].operator;
                        } else {
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
        printErr("invalid logical expression: indeterminate result\n", .{});
        return JsonPathError.InvalidPath;
    }
    return final_result.?;
}

fn evaluateLogicalExpressionSelector(allocator: std.mem.Allocator, expression: []u8, value: *const json.Value) JsonPathError!bool {
    // We're going to parse the expression into a series of primitive values and operators, then evaluate it
    // @ refers to the root value
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
                    printErr("invalid logical expression: unclosed grouping expression starting at index {}\n", .{group_expression_start});
                    return JsonPathError.InvalidPath;
                }
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
                // Call evaluateJsonPath with the expression slice and the root value
                const evaluated_value = try evaluateJsonPath(allocator, expression_slice, value, .{ .skip_root = true });
                // If the evaluated value is null, then return false
                if (evaluated_value == null) {
                    logical_expressions.append(.{ .value = null }) catch return JsonPathError.OutOfMemory;
                    continue :ex;
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
                logical_expressions.append(.{ .operator = .Equals }) catch return JsonPathError.OutOfMemory;
                continue :ex;
            },
            '!' => {
                // This can be !, !=
                expression_index += 1;
                if (expression_index >= expression.len) {
                    printErr("invalid logical expression: ends with ! operator\n", .{});
                    return JsonPathError.InvalidPath;
                }
                if (expression[expression_index] == '=') {
                    expression_index += 1;
                    logical_expressions.append(.{ .operator = .NotEquals }) catch return JsonPathError.OutOfMemory;
                    continue :ex;
                }
                return JsonPathError.InvalidPath;
            },
            '&' => { // &&
                // Next character must be &
                expression_index += 1;
                if (expression_index >= expression.len) {
                    printErr("invalid logical expression: ends with & operator\n", .{});
                    return JsonPathError.InvalidPath;
                }
                if (expression[expression_index] != '&') {
                    printErr("invalid logical expression: single & operator, logical AND must be &&\n", .{});
                    return JsonPathError.InvalidPath;
                }
                expression_index += 1;
                logical_expressions.append(.{ .operator = .And }) catch return JsonPathError.OutOfMemory;
                continue :ex;
            },
            '|' => { // ||
                expression_index += 1;
                if (expression_index >= expression.len) {
                    printErr("invalid logical expression: ends with | operator\n", .{});
                    return JsonPathError.InvalidPath;
                }
                if (expression[expression_index] != '|') {
                    printErr("invalid logical expression: single | operator, logical OR must be ||\n", .{});
                    return JsonPathError.InvalidPath;
                }
                expression_index += 1;
                logical_expressions.append(.{ .operator = .Or }) catch return JsonPathError.OutOfMemory;
                continue :ex;
            },
            '>' => {
                expression_index += 1;
                if (expression_index >= expression.len) {
                    printErr("invalid logical expression: ends with > operator\n", .{});
                    return JsonPathError.InvalidPath;
                }
                if (expression[expression_index] == '=') {
                    expression_index += 1;
                    logical_expressions.append(.{ .operator = .GreaterThanOrEqualTo }) catch return JsonPathError.OutOfMemory;
                } else {
                    logical_expressions.append(.{ .operator = .GreaterThan }) catch return JsonPathError.OutOfMemory;
                }
                continue :ex;
            },
            '<' => {
                expression_index += 1;
                if (expression_index >= expression.len) {
                    printErr("invalid logical expression: ends with < operator\n", .{});
                    return JsonPathError.InvalidPath;
                }
                if (expression[expression_index] == '=') {
                    expression_index += 1;
                    logical_expressions.append(.{ .operator = .LessThanOrEqualTo }) catch return JsonPathError.OutOfMemory;
                } else {
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
                    printErr("invalid logical expression: ends with unclosed quoted string\n", .{});
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
                    printErr("invalid logical expression: ends with unclosed quoted string\n", .{});
                    return JsonPathError.InvalidPath;
                }
                expression_index += 1;
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
                                printErr("invalid logical expression: invalid number at index {}\n", .{expression_index});
                                return JsonPathError.InvalidPath;
                            }
                            is_float = true;
                        },
                        '-' => {
                            if (expression_start_index != expression_index) {
                                printErr("invalid logical expression: invalid number at index {}\n", .{expression_index});
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
                logical_expressions.append(.{ .value = json.Value.parseFromNumberSlice(number_buffer.items) }) catch return JsonPathError.OutOfMemory;
                continue :ex;
            },
            // If we hit any lowercase alphabetic character, we will check if it matches one of the "builtins" (i.e. true, false, or a function - length, count, match, search, value)
            'a'...'z' => {
                // continue reading until we hit a non-alphabetic character
                var builtin_name_buffer = std.ArrayList(u8).init(allocator);
                var expr_char = expression[expression_index];
                while (expression_index < expression.len and expr_char >= 'a' and expr_char <= 'z') {
                    builtin_name_buffer.append(expr_char) catch return JsonPathError.OutOfMemory;
                    expression_index += 1;
                    if (expression_index < expression.len) {
                        expr_char = expression[expression_index];
                    }
                }
                // Check if the builtin name matches one of the builtins
                // All functions must be followed by a parentheses-enclosed
                if (std.mem.eql(u8, builtin_name_buffer.items, "true")) {
                    logical_expressions.append(.{ .value = json.Value{ .bool = true } }) catch return JsonPathError.OutOfMemory;
                } else if (std.mem.eql(u8, builtin_name_buffer.items, "false")) {
                    logical_expressions.append(.{ .value = json.Value{ .bool = false } }) catch return JsonPathError.OutOfMemory;
                } else if (std.mem.eql(u8, builtin_name_buffer.items, "length")) {
                    // length()
                    if (expression_index >= expression.len) {
                        return JsonPathError.InvalidLogicalExpression;
                    }
                    if (expression[expression_index] != '(') {
                        return JsonPathError.InvalidLogicalExpression;
                    }
                    expression_index += 1;
                    if (expression_index >= expression.len) {
                        return JsonPathError.InvalidLogicalExpression;
                    }
                    // Next should either be a @ indicating an expression or a ' indicating a string
                    switch (expression[expression_index]) {
                        '@' => {
                            expression_index += 1;
                            // Read the entire expression until we hit a closing ')' and evaluate it
                            var expression_buffer = std.ArrayList(u8).init(allocator);
                            while (expression_index < expression.len and (expression[expression_index] != ')')) {
                                expression_buffer.append(expression[expression_index]) catch return JsonPathError.OutOfMemory;
                                expression_index += 1;
                            }
                            if (expression_index >= expression.len) {
                                return JsonPathError.InvalidLogicalExpression;
                            }
                            if (expression[expression_index] != ')') {
                                return JsonPathError.InvalidLogicalExpression;
                            }
                            expression_index += 1;
                            const evaluated_value = try evaluateJsonPath(allocator, expression_buffer.items, value, .{ .skip_root = true });
                            if (evaluated_value == null) {
                                return false;
                            }
                            // Now get the length of the evaluated value
                            const length = lengthBuiltin(&evaluated_value.?);
                            if (length == null) {
                                return false;
                            }
                            logical_expressions.append(.{ .value = length.? }) catch return JsonPathError.OutOfMemory;
                        },
                        '\'' => {
                            expression_index += 1;
                            // Read the entire string until we hit another '
                            var string_buffer = std.ArrayList(u8).init(allocator);
                            var escape_next_char: bool = false;
                            expr_char = expression[expression_index];
                            while (expression_index < expression.len and (expr_char != '\'' or escape_next_char)) {
                                if (expr_char == '\\') {
                                    escape_next_char = true;
                                } else {
                                    string_buffer.append(expr_char) catch return JsonPathError.OutOfMemory;
                                    escape_next_char = false;
                                }
                                expression_index += 1;
                                if (expression_index < expression.len) {
                                    expr_char = expression[expression_index];
                                }
                            }
                            if (expression_index >= expression.len) {
                                return JsonPathError.InvalidLogicalExpression;
                            }
                            if (expression[expression_index] != '\'') {
                                return JsonPathError.InvalidLogicalExpression;
                            }
                            expression_index += 1;
                            logical_expressions.append(.{ .value = json.Value{ .integer = @intCast(string_buffer.items.len) } }) catch return JsonPathError.OutOfMemory;
                        },
                        else => return JsonPathError.InvalidLogicalExpression,
                    }
                } else if (std.mem.eql(u8, builtin_name_buffer.items, "count")) {
                    // count()
                    if (expression_index >= expression.len) {
                        return JsonPathError.InvalidLogicalExpression;
                    }
                    if (expression[expression_index] != '(') {
                        return JsonPathError.InvalidLogicalExpression;
                    }
                    expression_index += 1;
                    // Must be an expression that evaluates to an array
                    // Next char must be '@'
                    if (expression_index >= expression.len) {
                        return JsonPathError.InvalidLogicalExpression;
                    }
                    if (expression[expression_index] != '@') {
                        return JsonPathError.InvalidLogicalExpression;
                    }
                    expression_index += 1;
                    // Read the entire expression until we hit a closing ')' and evaluate it
                    var expression_buffer = std.ArrayList(u8).init(allocator);
                    while (expression_index < expression.len and (expression[expression_index] != ')')) {
                        expression_buffer.append(expression[expression_index]) catch return JsonPathError.OutOfMemory;
                        expression_index += 1;
                    }
                    if (expression_index >= expression.len) {
                        return JsonPathError.InvalidLogicalExpression;
                    }
                    if (expression[expression_index] != ')') {
                        return JsonPathError.InvalidLogicalExpression;
                    }
                    expression_index += 1;
                    const evaluated_value = try evaluateJsonPath(allocator, expression_buffer.items, value, .{ .skip_root = true });
                    if (evaluated_value == null) {
                        return false;
                    }
                    const count = countBuiltin(&evaluated_value.?);
                    if (count == null) {
                        return false;
                    }
                    logical_expressions.append(.{ .value = count.? }) catch return JsonPathError.OutOfMemory;
                }
            },
            else => return JsonPathError.InvalidPath,
        }
    }
    // Evaluate the logical expressions
    return try evaluateLogicalExpression(logical_expressions.items);
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Use book store JSON, find books by author
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, books_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("@.author == 'J. R. R. Tolkien'");
    // Loop through the root json and evaluate the path for each item
    // Only the last item should match
    var index: u64 = 0;
    for (root_json.array.items) |item| {
        const result = try evaluateLogicalExpressionSelector(alloc, path.items, &item);
        // stringify result, compare to expected
        const result_str = try json.stringifyAlloc(alloc, result, .{});
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, books_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("@.price > 8.99");
    var index: u64 = 0;
    for (root_json.array.items) |item| {
        const result = try evaluateLogicalExpressionSelector(alloc, path.items, &item);
        const result_str = try json.stringifyAlloc(alloc, result, .{});
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
                // Read the key for the next node (exit loop if ., [, ], or *)
                path_index += 1;
                if (path_index >= path.len) {
                    return JsonPathError.InvalidPath;
                }
                char = path[path_index];
                // '..' - evaluate all keys in the current node
                if (char == '.') {
                    // Error if not an object
                    if (current_node.* != .object) {
                        return undefined;
                    }
                    // If current node is not an object, then return undefined
                    if (current_node.* != .object) {
                        return undefined;
                    }
                    // Loop through all of the keys in the current node and evaluate the path for each key
                    // Create a new ArrayList to contain the evaluated keys
                    var evaluated_keys = std.ArrayList(json.Value).init(allocator);
                    for (current_node.object.keys()) |key| {
                        const evaluated_key = try evaluateJsonPath(allocator, path[path_index..], &current_node.object.get(key).?, .{ .skip_root = true });
                        evaluated_keys.append(evaluated_key.?) catch return JsonPathError.OutOfMemory;
                    }
                    return json.Value{ .array = evaluated_keys };
                } else if (char == '*') { // Select all children of the current node
                    path_index += 1;
                    var result_array = std.ArrayList(json.Value).init(allocator);
                    // If the current node is an array, then we will return all of the items in the array
                    if (current_node.* == .array) {
                        // Recursively evaluate the path for each item in the array
                        for (current_node.array.items) |item| {
                            const evaluated_item = try evaluateJsonPath(allocator, path[path_index..], &item, .{ .skip_root = true });
                            if (evaluated_item != null) {
                                result_array.append(evaluated_item.?) catch return JsonPathError.OutOfMemory;
                            }
                        }
                        return json.Value{ .array = result_array };
                    }
                    // If the current node is an object, then we will evaluate the remaining path for each child
                    if (current_node.* == .object) {
                        for (current_node.object.values()) |v| {
                            const evaluated_item = try evaluateJsonPath(allocator, path[path_index..], &v, .{ .skip_root = true });
                            if (evaluated_item != null) {
                                result_array.append(evaluated_item.?) catch return JsonPathError.OutOfMemory;
                            }
                        }
                        return json.Value{ .array = result_array };
                    }
                }
                // Error if not an object
                if (current_node.* != .object) {
                    return undefined;
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
                    printErr("invalid path: no node name at index {}\n", .{path_index});
                    return JsonPathError.InvalidPath;
                }
                // Try to get the next node using the key in the node_name_buffer
                const next_node = current_node.object.getPtr(node_name_buffer.items);
                if (next_node == null) {
                    return undefined;
                }
                current_node = next_node.?;
                // Clear node_name_buffer
                node_name_buffer.clearRetainingCapacity();
            },
            // Case 2: Selector
            '[' => {
                path_index += 1;
                if (path_index >= path.len) {
                    printErr("invalid path: ends with '['\n", .{});
                    return JsonPathError.InvalidPath;
                }
                char = path[path_index];
                // If the next character is a ', we are trying to get a node at the proceeding key, so read characters until we hit another '
                if (char == '\'') {
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
                        printErr("invalid path: ends with unclosed quoted string\n", .{});
                        return JsonPathError.InvalidPath;
                    }
                    path_index += 1;
                    // If the next character is not a ']', then return invalid path
                    if (path_index >= path.len) {
                        printErr("invalid path: ends with unclosed selector\n", .{});
                        return JsonPathError.InvalidPath;
                    }
                    char = path[path_index];
                    if (char != ']') {
                        printErr("invalid path: ends with unclosed selector\n", .{});
                        return JsonPathError.InvalidPath;
                    }
                    // Get the next node
                    const next_node = current_node.object.getPtr(node_name_buffer.items);
                    if (next_node == null) {
                        return undefined;
                    }
                    current_node = next_node.?;
                    path_index += 1;
                    continue :ev;
                }
                var selector_type: SelectorType = .Unknown;
                const selector_expression_start_index = path_index;
                // Read through the entire selector expression (until we hit a ])
                while (char != ']' and path_index < path.len) {
                    // We use the character to determine the selector type
                    switch (char) {
                        '*' => {
                            if (selector_type != .Unknown) {
                                printErr("invalid slice expression: cannot use '*' with ',' or ':'\n", .{});
                                return JsonPathError.InvalidPath;
                            }
                            selector_type = .All;
                        },
                        ':' => {
                            if (selector_type != .Unknown and selector_type != .Slice) {
                                printErr("invalid slice expression: cannot use ':' with ',' or '*'\n", .{});
                                return JsonPathError.InvalidPath;
                            }
                            selector_type = .Slice;
                        },
                        ',' => {
                            if (selector_type != .Unknown and selector_type != .Pick) {
                                printErr("invalid slice expression: cannot use ',' with '*' or ':'\n", .{});
                                return JsonPathError.InvalidPath;
                            }
                            selector_type = .Pick;
                        },
                        else => {
                            // If the first character is a ?, then we are evaluating an expression
                            if (char == '?' and path_index == selector_expression_start_index) {
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
                    printErr("invalid path: empty selector expression\n", .{});
                    return JsonPathError.InvalidPath;
                }
                // The default is pick
                if (selector_type == .Unknown) {
                    selector_type = .Pick;
                }
                // Evaluate the selector expression
                // We're going to be populating an ArrayList with the evaluated selector expression
                var sliced_array = std.ArrayList(json.Value).init(allocator);
                switch (selector_type) {
                    .Slice => {
                        // Must be Array
                        if (current_node.* != .array) {
                            return undefined;
                        }
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
                                        const parsed_int = std.fmt.parseInt(u64, parse_int_buffer.items, 10) catch {
                                            printErr("invalid slice expression: invalid number at index {}\n", .{selector_expression_index});
                                            return JsonPathError.InvalidPath;
                                        };
                                        switch (start_end_step) {
                                            0 => start = parsed_int,
                                            1 => end = parsed_int,
                                            2 => step = parsed_int,
                                            else => {
                                                printErr("invalid slice expression: too many ':' characters\n", .{});
                                                return JsonPathError.InvalidPath;
                                            },
                                        }
                                    }
                                    start_end_step += 1;
                                    if (start_end_step > 2) {
                                        printErr("invalid slice expression: too many ':' characters\n", .{});
                                        return JsonPathError.InvalidPath;
                                    }
                                    parse_int_buffer.clearRetainingCapacity();
                                },
                                else => {
                                    printErr("invalid slice expression: invalid character at index {}\n", .{selector_expression_index});
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
                                        printErr("invalid slice expression: too many ':' characters\n", .{});
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
                            printErr("invalid slice expression: step is 0\n", .{});
                            return JsonPathError.InvalidPath;
                        }
                        // If the step is negative, then iterate backwards through the array
                        // If the step is positive, then iterate forwards through the array
                        path_index += 1;
                        while (start < end) : (start += step) {
                            // Otherwise, we need to evaluate the rest of the path
                            const evaluated_item = try evaluateJsonPath(allocator, path[path_index..], &current_node.array.items[start], .{ .skip_root = true });
                            sliced_array.append(evaluated_item.?) catch return JsonPathError.OutOfMemory;
                        }
                        return json.Value{ .array = sliced_array };
                    },
                    .Pick => {
                        // Must be Array
                        if (current_node.* != .array) {
                            return undefined;
                        }
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
                                        const parsed_int = std.fmt.parseInt(u64, parse_int_buffer.items, 10) catch {
                                            printErr("invalid pick expression: invalid number at index {}\n", .{selector_expression_index});
                                            return JsonPathError.InvalidPath;
                                        };
                                        pick_items.append(parsed_int) catch return JsonPathError.OutOfMemory;
                                    } else {
                                        printErr("invalid pick expression: missing number at index {}\n", .{selector_expression_index});
                                        return JsonPathError.InvalidPath;
                                    }
                                },
                                else => {
                                    printErr("invalid pick expression: invalid character at index {}\n", .{selector_expression_index});
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
                        // Evaluate the expression (for either an array, or all of the child nodes of an object)
                        // Go through each item in the array and evaluate the expression
                        // If the expression is true for any item, then add it to the array
                        // Return the array
                        switch (current_node.*) {
                            .array => {
                                for (current_node.array.items) |item| {
                                    const filter_match = try evaluateLogicalExpressionSelector(allocator, path[selector_expression_start_index + 1 .. selector_expression_end_index], &item);
                                    if (filter_match) {
                                        sliced_array.append(item) catch return JsonPathError.OutOfMemory;
                                    }
                                }
                            },
                            .object => {
                                // Loop through all of the child nodes and evaluate the expression\
                                for (current_node.object.values()) |v| {
                                    const filter_match = try evaluateLogicalExpressionSelector(allocator, path[selector_expression_start_index + 1 .. selector_expression_end_index], &v);
                                    if (filter_match) {
                                        sliced_array.append(v) catch return JsonPathError.OutOfMemory;
                                    }
                                }
                            },
                            else => {
                                printErr("invalid path: expression selector must be used with an array or object\n", .{});
                                return JsonPathError.InvalidPath;
                            },
                        }
                        return json.Value{ .array = sliced_array };
                    },
                    .All => {
                        // Can be Array or Object
                        if (current_node.* != .array and current_node.* != .object) {
                            return undefined;
                        }
                        // Loop through all of the items in the current node and evaluate the rest of the path
                        path_index += 1;
                        for (current_node.array.items) |item| {
                            const evaluated_item = try evaluateJsonPath(allocator, path[path_index..], &item, .{ .skip_root = true });
                            sliced_array.append(evaluated_item.?) catch return JsonPathError.OutOfMemory;
                        }
                        return json.Value{ .array = sliced_array };
                    },
                    else => {
                        printErr("invalid path: invalid selector ex\n", .{});
                        return JsonPathError.InvalidPath;
                    },
                }
            },
            else => {
                printErr("invalid path: invalid character at index {}\n", .{path_index});
                return JsonPathError.InvalidPath;
            },
        }
    }
    // We're at the end of the evaluation. We will return the value at the current node
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc,
        \\{
        \\    "a": 1
        \\}
    , .{});
    // Initialize an ArrayList to contain the path string
    var path = std.ArrayList(u8).init(alloc);
    try path.append('$');
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqualDeep(root_json, result.?);

    try path.append('.');
    const result2 = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqualDeep(root_json, result2.?);
}

test "basic jsonpath 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc,
        \\{
        \\    "a": {
        \\        "b": 3
        \\    }
        \\}
    , .{});
    const expected = json.Value{ .integer = 3 };
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.a.b");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(expected.integer, result.?.integer);
}

test "array of integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc,
        \\[1, 2, 3, 4, 5]
    , .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$[1:3]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(result.?.array.items.len, 2);
    try testing.expectEqual(result.?.array.items[0].integer, 2);
    try testing.expectEqual(result.?.array.items[1].integer, 3);
}

test "basic slicing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, book_store_json, .{});
    var expected_json: json.Value = undefined;
    expected_json = try json.parseFromSliceLeaky(json.Value, alloc,
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
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(expected_json.array.items.len, result.?.array.items.len);
    // Loop through the expected array and compare each item
    for (expected_json.array.items, 0..) |item, i| {
        // Compare the two objects
        try testing.expectEqualDeep(item.object.get("author").?, result.?.array.items[i].object.get("author").?);
        try testing.expectEqualDeep(item.object.get("title").?, result.?.array.items[i].object.get("title").?);
        try testing.expectEqualDeep(item.object.get("isbn").?, result.?.array.items[i].object.get("isbn").?);
        try testing.expectEqualDeep(item.object.get("price").?, result.?.array.items[i].object.get("price").?);
    }
}

test "slicing and getting nested values from sliced array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.book[*].author");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(result.?.array.items.len, 4);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[0].string, "Nigel Rees"), true);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[1].string, "Evelyn Waugh"), true);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[2].string, "Herman Melville"), true);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[3].string, "J. R. R. Tolkien"), true);
}

test "using [''] syntax for selecting keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc,
        \\{
        \\    "a": {
        \\        "b": 3
        \\    }
        \\}
    , .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.a['b']");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(result.?.integer, 3);
}

test "basic picking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.book[0,2]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(result.?.array.items.len, 2);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[0].object.get("author").?.string, "Nigel Rees"), true);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[1].object.get("author").?.string, "Herman Melville"), true);
}

test "get single item from array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc,
        \\[1, 2, 3, 4, 5]
    , .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$[0]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(result.?.array.items[0].integer, 1);
}

test "basic expression selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.book[?@.price > 10]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(result.?.array.items.len, 2);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[0].object.get("author").?.string, "Evelyn Waugh"), true);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[1].object.get("author").?.string, "J. R. R. Tolkien"), true);
}

test "expression selector with nested groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.book[?(@.price < 10) && ((@.category != 'fiction') && (@.author == 'Nigel Rees' || @.author == 'Herman Melville'))]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(result.?.array.items.len, 1);
    try testing.expectEqual(true, std.mem.eql(u8, result.?.array.items[0].object.get("isbn").?.string, "0-553-21311-4"));
}

test "wildcard select all object children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.*");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    // One of these children should be an array with 4 items, the other should be an object with color = red and price = 399
    var array_found = false;
    var object_found = false;
    for (result.?.array.items) |item| {
        switch (item) {
            .array => {
                array_found = true;
                try testing.expectEqual(item.array.items.len, 4);
            },
            .object => {
                object_found = true;
                try testing.expectEqual(true, std.mem.eql(u8, item.object.get("color").?.string, "red"));
                try testing.expectEqual(item.object.get("price").?.integer, 399);
            },
            else => {
                try testing.expect(false);
            },
        }
    }
    try testing.expectEqual(array_found, true);
    try testing.expectEqual(object_found, true);
}

test "wildcard select all elements of array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.book.*");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(result.?.array.items.len, 4);
}

test "wildcard select subpath in child object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store.*.price");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(1, result.?.array.items.len);
    try testing.expectEqual(399, result.?.array.items[0].integer);
}

test "expression with length builtin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, book_store_json, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.store[?length(@) == 4]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(result.?.array.items.len, 1);
    try testing.expectEqual(result.?.array.items[0].array.items.len, 4);
}

const rfc_example_json_23521 =
    \\{
    \\    "obj": {"x": "y"},
    \\    "arr": [2, 3]
    \\}
;

// TODO
// $.absent1 == $.absent2 |  true  |    Empty nodelists
// $.absent1 <= $.absent2 |  true  |     == implies <=      |
//    $.absent == 'g'     | false  |     Empty nodelist     |
// $.absent1 != $.absent2 | false  |    Empty nodelists     |
//    $.absent != 'g'     |  true  |     Empty nodelist     |
//         1 <= 2         |  true  |   Numeric comparison   |
//         1 > 2          | false  |   Numeric comparison   |
//       13 == '13'       | false  |     Type mismatch      |
//       'a' <= 'b'       |  true  |   String comparison    |
//       'a' > 'b'        | false  |   String comparison    |
//     $.obj == $.arr     | false  |     Type mismatch      |
//     $.obj != $.arr     |  true  |     Type mismatch      |
//     $.obj == $.obj     |  true  |   Object comparison    |
//     $.obj != $.obj     | false  |   Object comparison    |
//     $.arr == $.arr     |  true  |    Array comparison    |
//     $.arr != $.arr     | false  |    Array comparison    |
//      $.obj == 17       | false  |     Type mismatch      |
//      $.obj != 17       |  true  |     Type mismatch      |
//     $.obj <= $.arr     | false  | Objects and arrays do  |
//                        |        | not offer < comparison |
//     $.obj < $.arr      | false  | Objects and arrays do  |
//                        |        | not offer < comparison |
//     $.obj <= $.obj     |  true  |     == implies <=      |
//     $.arr <= $.arr     |  true  |     == implies <=      |
//       1 <= $.arr       | false  | Arrays do not offer <  |
//                        |        |       comparison       |
//       1 >= $.arr       | false  | Arrays do not offer <  |
//                        |        |       comparison       |
//       1 > $.arr        | false  | Arrays do not offer <  |
//                        |        |       comparison       |
//       1 < $.arr        | false  | Arrays do not offer <  |
//                        |        |       comparison       |
//      true <= true      |  true  |     == implies <=      |
//      true > true       | false  | Booleans do not offer  |
//                        |        |      < comparison      |

const rfc_example_json_23522 =
    \\   {
    \\    "a": [3, 5, 1, 2, 4, 6,
    \\           {"b": "j"},
    \\           {"b": "k"},
    \\           {"b": {}},
    \\           {"b": "kilo"}
    \\          ],
    \\    "o": {"p": 1, "q": 2, "r": 3, "s": 5, "t": {"u": 6}},
    \\    "e": "f"
    \\}
;

// +==================+==============+=============+===================+
// |      Query       | Result       |    Result   | Comment           |
// |                  |              |    Paths    |                   |
// +==================+==============+=============+===================+
// |   $.a[?@.b ==    | {"b":        |  $['a'][9]  | Member value      |
// |     'kilo']      | "kilo"}      |             | comparison        |
// +------------------+--------------+-------------+-------------------+
test "$.a[?@.b == 'kilo']" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, rfc_example_json_23522, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.a[?@.b == 'kilo']");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(result.?.array.items.len, 1);
    try testing.expectEqual(std.mem.eql(u8, result.?.array.items[0].object.get("b").?.string, "kilo"), true);
}
// TODO
// |   $.a[?(@.b ==   | {"b":        |  $['a'][9]  | Equivalent query  |
// |     'kilo')]     | "kilo"}      |             | with enclosing    |
// |                  |              |             | parentheses       |
// +------------------+--------------+-------------+-------------------+
// |   $.a[?@>3.5]    | 5            |  $['a'][1]  | Array value       |
// |                  | 4            |  $['a'][4]  | comparison        |
// |                  | 6            |  $['a'][5]  |                   |
// +------------------+--------------+-------------+-------------------+
test "$.a[?@>3.5]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, rfc_example_json_23522, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.a[?@>3.5]");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(3, result.?.array.items.len);
    try testing.expectEqual(5, result.?.array.items[0].integer);
    try testing.expectEqual(4, result.?.array.items[1].integer);
    try testing.expectEqual(6, result.?.array.items[2].integer);
}

// TODO
// |    $.a[?@.b]     | {"b": "j"}   |  $['a'][6]  | Array value       |
// |                  | {"b": "k"}   |  $['a'][7]  | existence         |
// |                  | {"b": {}}    |  $['a'][8]  |                   |
// |                  | {"b":        |  $['a'][9]  |                   |
// |                  | "kilo"}      |             |                   |
// +------------------+--------------+-------------+-------------------+
// |     $[?@.*]      | [3, 5, 1,    |    $['a']   | Existence of non- |
// |                  | 2, 4, 6,     |    $['o']   | singular queries  |
// |                  | {"b": "j"},  |             |                   |
// |                  | {"b": "k"},  |             |                   |
// |                  | {"b": {}},   |             |                   |
// |                  | {"b":        |             |                   |
// |                  | "kilo"}]     |             |                   |
// |                  | {"p": 1,     |             |                   |
// |                  | "q": 2,      |             |                   |
// |                  | "r": 3,      |             |                   |
// |                  | "s": 5,      |             |                   |
// |                  | "t": {"u":   |             |                   |
// |                  | 6}}          |             |                   |
// +------------------+--------------+-------------+-------------------+
// |   $[?@[?@.b]]    | [3, 5, 1,    |    $['a']   | Nested filters    |
// |                  | 2, 4, 6,     |             |                   |
// |                  | {"b": "j"},  |             |                   |
// |                  | {"b": "k"},  |             |                   |
// |                  | {"b": {}},   |             |                   |
// |                  | {"b":        |             |                   |
// |                  | "kilo"}]     |             |                   |
// +------------------+--------------+-------------+-------------------+
// | $.o[?@<3, ?@<3]  | 1            | $['o']['p'] | Non-deterministic |
// |                  | 2            | $['o']['q'] | ordering          |
// |                  | 2            | $['o']['q'] |                   |
// |                  | 1            | $['o']['p'] |                   |
// +------------------+--------------+-------------+-------------------+
// | $.a[?@<2 || @.b  | 1            |  $['a'][2]  | Array value       |
// |     == "k"]      | {"b": "k"}   |  $['a'][7]  | logical OR        |
// +------------------+--------------+-------------+-------------------+
test "$.a[?@<2 || @.b == 'k']" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var root_json: json.Value = undefined;
    root_json = try json.parseFromSliceLeaky(json.Value, alloc, rfc_example_json_23522, .{});
    var path = std.ArrayList(u8).init(alloc);
    try path.appendSlice("$.a[?@<2 || @.b == 'k']");
    const result = try evaluateJsonPath(alloc, path.items, &root_json, .{});
    try testing.expectEqual(2, result.?.array.items.len);
    try testing.expectEqual(1, result.?.array.items[0].integer);
    try testing.expectEqual(true, std.mem.eql(u8, result.?.array.items[1].object.get("b").?.string, "k"));
}

// | $.a[?match(@.b,  | {"b": "j"}   |  $['a'][6]  | Array value       |
// |     "[jk]")]     | {"b": "k"}   |  $['a'][7]  | regular           |
// |                  |              |             | expression match  |
// +------------------+--------------+-------------+-------------------+
// | $.a[?search(@.b, | {"b": "j"}   |  $['a'][6]  | Array value       |
// |     "[jk]")]     | {"b": "k"}   |  $['a'][7]  | regular           |
// |                  | {"b":        |  $['a'][9]  | expression search |
// |                  | "kilo"}      |             |                   |
// +------------------+--------------+-------------+-------------------+
// | $.o[?@>1 && @<4] | 2            | $['o']['q'] | Object value      |
// |                  | 3            | $['o']['r'] | logical AND       |
// +------------------+--------------+-------------+-------------------+
// | $.o[?@>1 && @<4] | 3            | $['o']['r'] | Alternative       |
// |                  | 2            | $['o']['q'] | result            |
// +------------------+--------------+-------------+-------------------+
// | $.o[?@.u || @.x] | {"u": 6}     | $['o']['t'] | Object value      |
// |                  |              |             | logical OR        |
// +------------------+--------------+-------------+-------------------+
// | $.a[?@.b == $.x] | 3            |  $['a'][0]  | Comparison of     |
// |                  | 5            |  $['a'][1]  | queries with no   |
// |                  | 1            |  $['a'][2]  | values            |
// |                  | 2            |  $['a'][3]  |                   |
// |                  | 4            |  $['a'][4]  |                   |
// |                  | 6            |  $['a'][5]  |                   |
// +------------------+--------------+-------------+-------------------+
// |   $.a[?@ == @]   | 3            |  $['a'][0]  | Comparisons of    |
// |                  | 5            |  $['a'][1]  | primitive and of  |
// |                  | 1            |  $['a'][2]  | structured values |
// |                  | 2            |  $['a'][3]  |                   |
// |                  | 4            |  $['a'][4]  |                   |
// |                  | 6            |  $['a'][5]  |                   |
// |                  | {"b": "j"}   |  $['a'][6]  |                   |
// |                  | {"b": "k"}   |  $['a'][7]  |                   |
// |                  | {"b": {}}    |  $['a'][8]  |                   |
// |                  | {"b":        |  $['a'][9]  |                   |
// |                  | "kilo"}      |             |                   |
