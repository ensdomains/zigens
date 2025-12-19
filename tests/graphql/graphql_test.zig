const std = @import("std");
const testing = std.testing;
const graphql = @import("graphql");
const parser = graphql.parser;

// Unit tests for GraphQL parser with advanced filters and sorting

test "parse domain query with name_contains_nocase filter" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domains(where: {name_contains_nocase: "test"}, first: 5) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), document.operations.len);
    const operation = document.operations[0];
    try testing.expectEqual(@as(usize, 1), operation.fields.len);

    const field = operation.fields[0];
    try testing.expectEqualStrings("domains", field.name);

    // Check that filter argument exists
    var found_filter = false;
    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            found_filter = true;
            try testing.expect(arg.value == .object);

            // Check filter contains name_contains_nocase
            var found_nocase = false;
            for (arg.value.object) |filter_arg| {
                if (std.mem.eql(u8, filter_arg.name, "name_contains_nocase")) {
                    found_nocase = true;
                    try testing.expect(filter_arg.value == .string);
                    try testing.expectEqualStrings("test", filter_arg.value.string);
                }
            }
            try testing.expect(found_nocase);
        }
    }
    try testing.expect(found_filter);
}

test "parse domain query with name_starts_with filter" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domains(where: {name_starts_with: "vitalik"}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const field = document.operations[0].fields[0];

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            for (arg.value.object) |filter_arg| {
                if (std.mem.eql(u8, filter_arg.name, "name_starts_with")) {
                    try testing.expectEqualStrings("vitalik", filter_arg.value.string);
                    return;
                }
            }
        }
    }
    try testing.expect(false); // Should have found the filter
}

test "parse domain query with name_ends_with filter" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domains(where: {name_ends_with: ".eth"}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const field = document.operations[0].fields[0];

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            for (arg.value.object) |filter_arg| {
                if (std.mem.eql(u8, filter_arg.name, "name_ends_with")) {
                    try testing.expectEqualStrings(".eth", filter_arg.value.string);
                    return;
                }
            }
        }
    }
    try testing.expect(false);
}

test "parse domain query with owner_in filter" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domains(where: {owner_in: ["0x1234", "0x5678"]}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const field = document.operations[0].fields[0];

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            for (arg.value.object) |filter_arg| {
                if (std.mem.eql(u8, filter_arg.name, "owner_in")) {
                    try testing.expect(filter_arg.value == .list);
                    try testing.expectEqual(@as(usize, 2), filter_arg.value.list.len);
                    try testing.expectEqualStrings("0x1234", filter_arg.value.list[0].string);
                    try testing.expectEqualStrings("0x5678", filter_arg.value.list[1].string);
                    return;
                }
            }
        }
    }
    try testing.expect(false);
}

test "parse domain query with orderBy and orderDirection" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domains(orderBy: name, orderDirection: desc, first: 10) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const field = document.operations[0].fields[0];

    var found_order_by = false;
    var found_order_direction = false;

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "orderBy")) {
            found_order_by = true;
            try testing.expect(arg.value == .string);
            try testing.expectEqualStrings("name", arg.value.string);
        } else if (std.mem.eql(u8, arg.name, "orderDirection")) {
            found_order_direction = true;
            try testing.expect(arg.value == .string);
            try testing.expectEqualStrings("desc", arg.value.string);
        }
    }

    try testing.expect(found_order_by);
    try testing.expect(found_order_direction);
}

test "parse registration query with expiryDate_gte filter" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  registrations(where: {expiryDate_gte: 1700000000}) {
        \\    name
        \\    expiryDate
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const field = document.operations[0].fields[0];
    try testing.expectEqualStrings("registrations", field.name);

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            for (arg.value.object) |filter_arg| {
                if (std.mem.eql(u8, filter_arg.name, "expiryDate_gte")) {
                    try testing.expect(filter_arg.value == .int);
                    try testing.expectEqual(@as(i64, 1700000000), filter_arg.value.int);
                    return;
                }
            }
        }
    }
    try testing.expect(false);
}

test "parse registration query with expiryDate_lte filter" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  registrations(where: {expiryDate_lte: 2000000000}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const field = document.operations[0].fields[0];

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            for (arg.value.object) |filter_arg| {
                if (std.mem.eql(u8, filter_arg.name, "expiryDate_lte")) {
                    try testing.expectEqual(@as(i64, 2000000000), filter_arg.value.int);
                    return;
                }
            }
        }
    }
    try testing.expect(false);
}

test "parse registration query with registrant_in filter" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  registrations(where: {registrant_in: ["0xabc", "0xdef"]}) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const field = document.operations[0].fields[0];

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            for (arg.value.object) |filter_arg| {
                if (std.mem.eql(u8, filter_arg.name, "registrant_in")) {
                    try testing.expect(filter_arg.value == .list);
                    try testing.expectEqual(@as(usize, 2), filter_arg.value.list.len);
                    return;
                }
            }
        }
    }
    try testing.expect(false);
}

test "parse combined filter and sort query" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  domains(
        \\    where: {name_contains_nocase: "eth"}
        \\    orderBy: name
        \\    orderDirection: asc
        \\    first: 5
        \\  ) {
        \\    name
        \\    createdAt
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const field = document.operations[0].fields[0];

    var has_filter = false;
    var has_order_by = false;
    var has_order_direction = false;
    var has_first = false;

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "where")) {
            has_filter = true;
        } else if (std.mem.eql(u8, arg.name, "orderBy")) {
            has_order_by = true;
        } else if (std.mem.eql(u8, arg.name, "orderDirection")) {
            has_order_direction = true;
        } else if (std.mem.eql(u8, arg.name, "first")) {
            has_first = true;
        }
    }

    try testing.expect(has_filter);
    try testing.expect(has_order_by);
    try testing.expect(has_order_direction);
    try testing.expect(has_first);

    // Check selections
    try testing.expectEqual(@as(usize, 2), field.selections.len);
    try testing.expectEqualStrings("name", field.selections[0].name);
    try testing.expectEqualStrings("createdAt", field.selections[1].name);
}

test "parse registration sorting by expiryDate" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  registrations(orderBy: expiryDate, orderDirection: desc) {
        \\    name
        \\    expiryDate
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const field = document.operations[0].fields[0];

    var found_order = false;
    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "orderBy")) {
            try testing.expectEqualStrings("expiryDate", arg.value.string);
            found_order = true;
        }
    }
    try testing.expect(found_order);
}

test "parse registration sorting by registrationDate" {
    const allocator = testing.allocator;

    const query =
        \\query {
        \\  registrations(orderBy: registrationDate, orderDirection: asc) {
        \\    name
        \\  }
        \\}
    ;

    var p = try parser.Parser.init(allocator, query);
    var document = try p.parseDocument();
    defer document.deinit(allocator);

    const field = document.operations[0].fields[0];

    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "orderBy")) {
            try testing.expectEqualStrings("registrationDate", arg.value.string);
            return;
        }
    }
    try testing.expect(false);
}

// Unit tests for filter logic

test "case insensitive string matching" {
    const allocator = testing.allocator;

    const name = "VitalikButerin.eth";
    const filter = "VITALIK";

    const lower_name = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(lower_name);
    const lower_filter = try std.ascii.allocLowerString(allocator, filter);
    defer allocator.free(lower_filter);

    try testing.expect(std.mem.indexOf(u8, lower_name, lower_filter) != null);
}

test "string prefix matching" {
    const name = "vitalik.eth";
    try testing.expect(std.mem.startsWith(u8, name, "vitalik"));
    try testing.expect(!std.mem.startsWith(u8, name, "buterin"));
}

test "string suffix matching" {
    const name = "vitalik.eth";
    try testing.expect(std.mem.endsWith(u8, name, ".eth"));
    try testing.expect(!std.mem.endsWith(u8, name, ".com"));
}

test "timestamp range filtering" {
    const timestamp: i64 = 1700000000;
    const filter_gte: i64 = 1600000000;
    const filter_lte: i64 = 1800000000;

    try testing.expect(timestamp >= filter_gte);
    try testing.expect(timestamp <= filter_lte);
}

test "sorting comparison - ascending strings" {
    const a = "alice.eth";
    const b = "bob.eth";
    const cmp = std.mem.order(u8, a, b);
    try testing.expectEqual(std.math.Order.lt, cmp);
}

test "sorting comparison - descending strings" {
    const a = "bob.eth";
    const b = "alice.eth";
    const cmp = std.mem.order(u8, a, b);
    try testing.expectEqual(std.math.Order.gt, cmp);
}

test "sorting comparison - ascending timestamps" {
    const a: i64 = 1000000000;
    const b: i64 = 2000000000;
    try testing.expect(a < b);
}
