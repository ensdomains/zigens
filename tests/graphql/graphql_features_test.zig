const std = @import("std");
const testing = std.testing;
const graphql = @import("graphql");
const parser = graphql.parser;
const pagination = graphql.pagination;

// ============================================================================
// GRAPHQL FEATURES TESTS (FULL COVERAGE)
// Tests for all implemented GraphQL spec features:
// - Field aliases
// - Fragment definitions and spreads
// - Inline fragments
// - Directives (@skip, @include)
// - Variable definitions and defaults
// - List type modifiers
// - Type validation helpers
// - Pagination (forward and backward)
// ============================================================================

// ============================================================================
// FIELD ALIAS TESTS
// ============================================================================

test "alias: parse simple field alias" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  myDomain: domain(id: "test.eth") {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expectEqualStrings("myDomain", field.alias.?);
    try testing.expectEqualStrings("domain", field.name);
}

test "alias: parse field without alias" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(field.alias == null);
    try testing.expectEqualStrings("domain", field.name);
}

test "alias: parse nested field alias" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    domainName: name
        \\    ownerInfo: owner {
        \\      ownerId: id
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain = &doc.operations[0].fields[0];
    try testing.expectEqualStrings("domainName", domain.selections[0].alias.?);
    try testing.expectEqualStrings("name", domain.selections[0].name);
    try testing.expectEqualStrings("ownerInfo", domain.selections[1].alias.?);
    try testing.expectEqualStrings("owner", domain.selections[1].name);
}

test "alias: parse multiple aliased queries" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  first: domain(id: "vitalik.eth") { name }
        \\  second: domain(id: "nick.eth") { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), doc.operations[0].fields.len);
    try testing.expectEqualStrings("first", doc.operations[0].fields[0].alias.?);
    try testing.expectEqualStrings("second", doc.operations[0].fields[1].alias.?);
}

test "alias: response name is alias when present, name otherwise" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  myAlias: domain(id: "test.eth") { name }
        \\  domain(id: "other.eth") { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    // With alias, the response key should be the alias
    try testing.expectEqualStrings("myAlias", doc.operations[0].fields[0].alias.?);
    // Without alias, the response key should be the name
    try testing.expect(doc.operations[0].fields[1].alias == null);
    try testing.expectEqualStrings("domain", doc.operations[0].fields[1].name);
}

// ============================================================================
// FRAGMENT DEFINITION AND SPREAD TESTS
// ============================================================================

test "fragment: parse simple fragment definition" {
    const allocator = testing.allocator;

    const query =
        \\fragment DomainFields on Domain {
        \\  id
        \\  name
        \\  labelName
        \\}
        \\
        \\{
        \\  domain(id: "test.eth") {
        \\    ...DomainFields
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), doc.fragments.len);
    try testing.expectEqualStrings("DomainFields", doc.fragments[0].name);
    try testing.expectEqualStrings("Domain", doc.fragments[0].type_condition);
    try testing.expectEqual(@as(usize, 3), doc.fragments[0].selections.len);
}

test "fragment: parse fragment spread" {
    const allocator = testing.allocator;

    const query =
        \\fragment OwnerFields on Account {
        \\  id
        \\}
        \\
        \\{
        \\  domain(id: "test.eth") {
        \\    name
        \\    ...OwnerFields
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 2), domain_field.selections.len);
    try testing.expect(domain_field.selections[1].isFragmentSpread());
    try testing.expectEqualStrings("OwnerFields", domain_field.selections[1].fragment_spread.?);
}

test "fragment: multiple fragments" {
    const allocator = testing.allocator;

    const query =
        \\fragment F1 on Domain { id }
        \\fragment F2 on Domain { name }
        \\fragment F3 on Account { id }
        \\
        \\{ domain(id: "x") { ...F1 ...F2 } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), doc.fragments.len);
}

test "fragment: can look up fragment by name" {
    const allocator = testing.allocator;

    const query =
        \\fragment TestFrag on Domain { name }
        \\{ domain(id: "x") { ...TestFrag } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    // Look up fragment manually by iterating
    var found_name: ?[]const u8 = null;
    for (doc.fragments) |frag| {
        if (std.mem.eql(u8, frag.name, "TestFrag")) {
            found_name = frag.name;
            break;
        }
    }
    try testing.expect(found_name != null);
    try testing.expectEqualStrings("TestFrag", found_name.?);
}

// ============================================================================
// INLINE FRAGMENT TESTS
// ============================================================================

test "inline fragment: with type condition" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    id
        \\    ... on Domain {
        \\      name
        \\      owner { id }
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 2), domain_field.selections.len);

    const inline_frag = &domain_field.selections[1];
    try testing.expectEqualStrings("Domain", inline_frag.name);
    try testing.expect(inline_frag.fragment_spread == null);
    try testing.expectEqual(@as(usize, 2), inline_frag.selections.len);
}

test "inline fragment: multiple inline fragments" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  node(id: "123") {
        \\    id
        \\    ... on Domain { name }
        \\    ... on Account { domains { id } }
        \\    ... on Resolver { address }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const node_field = &doc.operations[0].fields[0];
    try testing.expectEqual(@as(usize, 4), node_field.selections.len);
    try testing.expectEqualStrings("Domain", node_field.selections[1].name);
    try testing.expectEqualStrings("Account", node_field.selections[2].name);
    try testing.expectEqualStrings("Resolver", node_field.selections[3].name);
}

test "inline fragment: nested inline fragments" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    ... on Domain {
        \\      owner {
        \\        ... on Account {
        \\          id
        \\          domains { name }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const domain_field = &doc.operations[0].fields[0];
    const outer_frag = &domain_field.selections[0];
    try testing.expectEqualStrings("Domain", outer_frag.name);

    const owner_field = &outer_frag.selections[0];
    const inner_frag = &owner_field.selections[0];
    try testing.expectEqualStrings("Account", inner_frag.name);
}

// ============================================================================
// DIRECTIVE TESTS (@skip and @include)
// ============================================================================

test "directive: @skip with boolean literal true" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name
        \\    owner @skip(if: true) { id }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const owner_field = &doc.operations[0].fields[0].selections[1];
    try testing.expectEqual(@as(usize, 1), owner_field.directives.len);
    try testing.expectEqualStrings("skip", owner_field.directives[0].name);
    try testing.expect(owner_field.directives[0].arguments[0].value.boolean == true);
}

test "directive: @include with boolean literal false" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name @include(if: false)
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const name_field = &doc.operations[0].fields[0].selections[0];
    try testing.expectEqual(@as(usize, 1), name_field.directives.len);
    try testing.expectEqualStrings("include", name_field.directives[0].name);
    try testing.expect(name_field.directives[0].arguments[0].value.boolean == false);
}

test "directive: with variable reference" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($showOwner: Boolean!) {
        \\  domain(id: "test.eth") {
        \\    name
        \\    owner @include(if: $showOwner) { id }
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const owner_field = &doc.operations[0].fields[0].selections[1];
    try testing.expectEqualStrings("showOwner", owner_field.directives[0].arguments[0].value.variable);
}

test "directive: shouldSkip returns true for @skip(if: true)" {
    const allocator = testing.allocator;

    const query =
        \\{ field @skip(if: true) }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(field.shouldSkip(null) == true);
}

test "directive: shouldSkip returns false for @skip(if: false)" {
    const allocator = testing.allocator;

    const query =
        \\{ field @skip(if: false) }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(field.shouldSkip(null) == false);
}

test "directive: shouldSkip returns false for @include(if: true)" {
    const allocator = testing.allocator;

    const query =
        \\{ field @include(if: true) }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(field.shouldSkip(null) == false);
}

test "directive: shouldSkip returns true for @include(if: false)" {
    const allocator = testing.allocator;

    const query =
        \\{ field @include(if: false) }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(field.shouldSkip(null) == true);
}

test "directive: shouldSkip with variables" {
    const allocator = testing.allocator;

    const query =
        \\query ($skip: Boolean!) {
        \\  field @skip(if: $skip)
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];

    var variables = std.StringHashMap(std.json.Value).init(allocator);
    defer variables.deinit();
    try variables.put("skip", std.json.Value{ .bool = true });

    try testing.expect(field.shouldSkip(&variables) == true);

    try variables.put("skip", std.json.Value{ .bool = false });
    try testing.expect(field.shouldSkip(&variables) == false);
}

test "directive: shouldSkip returns false for field without directives" {
    const allocator = testing.allocator;

    const query =
        \\{ field }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(field.shouldSkip(null) == false);
}

test "directive: multiple directives on same field" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  domain(id: "test.eth") {
        \\    name @skip(if: false) @include(if: true)
        \\  }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const name_field = &doc.operations[0].fields[0].selections[0];
    try testing.expectEqual(@as(usize, 2), name_field.directives.len);
    try testing.expectEqualStrings("skip", name_field.directives[0].name);
    try testing.expectEqualStrings("include", name_field.directives[1].name);
}

// ============================================================================
// VARIABLE DEFINITION TESTS
// ============================================================================

test "variable: simple variable definition" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($id: String!) {
        \\  domain(id: $id) { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), doc.operations[0].variables.len);
    const var_def = &doc.operations[0].variables[0];
    try testing.expectEqualStrings("id", var_def.name);
    try testing.expectEqualStrings("String", var_def.type_name);
    try testing.expect(var_def.required == true);
    try testing.expect(var_def.default_value == null);
}

test "variable: nullable variable" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($id: String) {
        \\  domain(id: $id) { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.required == false);
}

test "variable: multiple variables" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($first: Int!, $after: String, $owner: String!) {
        \\  domains(first: $first, after: $after, owner: $owner) { id }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), doc.operations[0].variables.len);
    try testing.expect(doc.operations[0].variables[0].required == true);
    try testing.expect(doc.operations[0].variables[1].required == false);
    try testing.expect(doc.operations[0].variables[2].required == true);
}

test "variable: string default value" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($id: String = "vitalik.eth") {
        \\  domain(id: $id) { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.default_value != null);
    try testing.expectEqualStrings("vitalik.eth", var_def.default_value.?.string);
}

test "variable: int default value" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($first: Int = 10) {
        \\  domains(first: $first) { id }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.default_value != null);
    try testing.expectEqual(@as(i64, 10), var_def.default_value.?.int);
}

test "variable: boolean default value true" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($showOwner: Boolean = true) {
        \\  domain(id: "test.eth") { name owner @include(if: $showOwner) { id } }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.default_value != null);
    try testing.expect(var_def.default_value.?.boolean == true);
}

test "variable: boolean default value false" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($skip: Boolean = false) {
        \\  domain(id: "test.eth") { name @skip(if: $skip) }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.default_value != null);
    try testing.expect(var_def.default_value.?.boolean == false);
}

test "variable: null default value" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($filter: String = null) {
        \\  domains(filter: $filter) { id }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.default_value != null);
    try testing.expect(var_def.default_value.? == .null_value);
}

test "variable: reference in argument" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($id: String!) {
        \\  domain(id: $id) { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const arg = &doc.operations[0].fields[0].arguments[0];
    try testing.expectEqualStrings("id", arg.name);
    try testing.expectEqualStrings("id", arg.value.variable);
}

test "variable: typeString for simple types" {
    const allocator = testing.allocator;

    const query =
        \\query Test($a: String, $b: String!) {
        \\  test
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const type_str_a = try doc.operations[0].variables[0].typeString(allocator);
    defer allocator.free(type_str_a);
    try testing.expectEqualStrings("String", type_str_a);

    const type_str_b = try doc.operations[0].variables[1].typeString(allocator);
    defer allocator.free(type_str_b);
    try testing.expectEqualStrings("String!", type_str_b);
}

// ============================================================================
// LIST TYPE MODIFIER TESTS
// ============================================================================

test "list: nullable list of nullable items [String]" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($ids: [String]) {
        \\  domains(ids: $ids) { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.is_list == true);
    try testing.expect(var_def.list_item_required == false);
    try testing.expect(var_def.required == false);
}

test "list: nullable list of required items [String!]" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($ids: [String!]) {
        \\  domains(ids: $ids) { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.is_list == true);
    try testing.expect(var_def.list_item_required == true);
    try testing.expect(var_def.required == false);
}

test "list: required list of nullable items [String]!" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($ids: [String]!) {
        \\  domains(ids: $ids) { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.is_list == true);
    try testing.expect(var_def.list_item_required == false);
    try testing.expect(var_def.required == true);
}

test "list: required list of required items [String!]!" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($ids: [String!]!) {
        \\  domains(ids: $ids) { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.is_list == true);
    try testing.expect(var_def.list_item_required == true);
    try testing.expect(var_def.required == true);
}

test "list: simple type is not a list" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomain($id: String!) {
        \\  domain(id: $id) { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.is_list == false);
}

test "list: typeString for list types" {
    const allocator = testing.allocator;

    const query =
        \\query Test($a: [String], $b: [String!], $c: [String]!, $d: [String!]!) {
        \\  test
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const type_a = try doc.operations[0].variables[0].typeString(allocator);
    defer allocator.free(type_a);
    try testing.expectEqualStrings("[String]", type_a);

    const type_b = try doc.operations[0].variables[1].typeString(allocator);
    defer allocator.free(type_b);
    try testing.expectEqualStrings("[String!]", type_b);

    const type_c = try doc.operations[0].variables[2].typeString(allocator);
    defer allocator.free(type_c);
    try testing.expectEqualStrings("[String]!", type_c);

    const type_d = try doc.operations[0].variables[3].typeString(allocator);
    defer allocator.free(type_d);
    try testing.expectEqualStrings("[String!]!", type_d);
}

test "list: with default value" {
    const allocator = testing.allocator;

    const query =
        \\query GetDomains($ids: [String!] = ["a", "b"]) {
        \\  domains(ids: $ids) { name }
        \\}
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const var_def = &doc.operations[0].variables[0];
    try testing.expect(var_def.is_list == true);
    try testing.expect(var_def.default_value != null);
    try testing.expect(var_def.default_value.? == .list);
}

// ============================================================================
// TYPE VALIDATION TESTS
// ============================================================================

test "validation: getRequiredStringArg returns string value" {
    const allocator = testing.allocator;

    const query =
        \\{ domain(id: "test.eth") { name } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const value = try parser.getRequiredStringArg(field, "id");
    try testing.expectEqualStrings("test.eth", value);
}

test "validation: getRequiredStringArg returns error for missing argument" {
    const allocator = testing.allocator;

    const query =
        \\{ domain { name } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const result = parser.getRequiredStringArg(field, "id");
    try testing.expectError(parser.ValidationError.MissingRequiredArgument, result);
}

test "validation: getRequiredStringArg returns error for wrong type" {
    const allocator = testing.allocator;

    const query =
        \\{ domain(id: 123) { name } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const result = parser.getRequiredStringArg(field, "id");
    try testing.expectError(parser.ValidationError.InvalidArgumentType, result);
}

test "validation: getRequiredIntArg returns int value" {
    const allocator = testing.allocator;

    const query =
        \\{ domains(first: 10) { name } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const value = try parser.getRequiredIntArg(field, "first");
    try testing.expectEqual(@as(i64, 10), value);
}

test "validation: getRequiredBoolArg returns bool value" {
    const allocator = testing.allocator;

    const query =
        \\{ domains(active: true) { name } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    const value = try parser.getRequiredBoolArg(field, "active");
    try testing.expect(value == true);
}

test "validation: validateValueType accepts correct types" {
    try parser.validateValueType(parser.Value{ .string = "test" }, "String", false);
    try parser.validateValueType(parser.Value{ .int = 42 }, "Int", false);
    try parser.validateValueType(parser.Value{ .boolean = true }, "Boolean", false);
    try parser.validateValueType(parser.Value{ .float = 3.14 }, "Float", false);
    try parser.validateValueType(parser.Value{ .int = 42 }, "Float", false); // Int coerces to Float
    try parser.validateValueType(parser.Value{ .string = "abc" }, "ID", false);
}

test "validation: validateValueType rejects wrong type" {
    const result = parser.validateValueType(parser.Value{ .string = "test" }, "Int", false);
    try testing.expectError(parser.ValidationError.InvalidArgumentType, result);
}

test "validation: validateValueType allows null for nullable type" {
    try parser.validateValueType(parser.Value.null_value, "String", false);
}

test "validation: validateValueType rejects null for required type" {
    const result = parser.validateValueType(parser.Value.null_value, "String", true);
    try testing.expectError(parser.ValidationError.NullNotAllowed, result);
}

test "validation: hasArg returns correct result" {
    const allocator = testing.allocator;

    const query =
        \\{ domain(id: "test.eth") { name } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];
    try testing.expect(parser.hasArg(field, "id") == true);
    try testing.expect(parser.hasArg(field, "nonexistent") == false);
}

test "validation: getValueTypeName returns correct names" {
    try testing.expectEqualStrings("Int", parser.getValueTypeName(parser.Value{ .int = 0 }));
    try testing.expectEqualStrings("Float", parser.getValueTypeName(parser.Value{ .float = 0.0 }));
    try testing.expectEqualStrings("String", parser.getValueTypeName(parser.Value{ .string = "" }));
    try testing.expectEqualStrings("Boolean", parser.getValueTypeName(parser.Value{ .boolean = true }));
    try testing.expectEqualStrings("Null", parser.getValueTypeName(parser.Value.null_value));
}

test "validation: optional getters with defaults" {
    const allocator = testing.allocator;

    const query =
        \\{ domain(id: "test.eth") { name } }
    ;

    var doc = try parser.parseQuery(allocator, query);
    defer doc.deinit(allocator);

    const field = &doc.operations[0].fields[0];

    // Existing arg returns value
    try testing.expectEqualStrings("test.eth", parser.getStringArg(field, "id", "default").?);

    // Missing arg returns default
    try testing.expectEqualStrings("default", parser.getStringArg(field, "missing", "default").?);

    // Missing arg with null default returns null
    try testing.expect(parser.getStringArg(field, "missing", null) == null);
}

// ============================================================================
// ERROR HANDLING TESTS
// ============================================================================

test "error: parse fails for invalid syntax" {
    const allocator = testing.allocator;

    const query =
        \\{
        \\  (id: "test.eth") {
        \\    name
        \\  }
        \\}
    ;

    // Parser should return an error for invalid syntax
    if (parser.parseQuery(allocator, query)) |_| {
        try testing.expect(false); // Should not succeed
    } else |_| {
        // Expected to fail
    }
}

test "empty query parses to empty document" {
    const allocator = testing.allocator;

    // Empty query results in document with no operations
    var doc = try parser.parseQuery(allocator, "");
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), doc.operations.len);
}

test "whitespace-only query parses to empty document" {
    const allocator = testing.allocator;

    // Whitespace-only query results in document with no operations
    var doc = try parser.parseQuery(allocator, "   \n\t  ");
    defer doc.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), doc.operations.len);
}

// ============================================================================
// PAGINATION TESTS
// ============================================================================

test "pagination: forward with first only" {
    const params = try pagination.PaginationParams.parse(10, null, null, null, 100, 1000);
    try testing.expectEqual(pagination.Direction.forward, params.direction);
    try testing.expectEqual(@as(usize, 10), params.limit);
    try testing.expect(params.cursor == null);
}

test "pagination: forward with first and after" {
    const params = try pagination.PaginationParams.parse(10, "cursor", null, null, 100, 1000);
    try testing.expectEqual(pagination.Direction.forward, params.direction);
    try testing.expectEqualStrings("cursor", params.cursor.?);
}

test "pagination: backward with last only" {
    const params = try pagination.PaginationParams.parse(null, null, 5, null, 100, 1000);
    try testing.expectEqual(pagination.Direction.backward, params.direction);
    try testing.expectEqual(@as(usize, 5), params.limit);
}

test "pagination: backward with last and before" {
    const params = try pagination.PaginationParams.parse(null, null, 5, "cursor", 100, 1000);
    try testing.expectEqual(pagination.Direction.backward, params.direction);
    try testing.expectEqualStrings("cursor", params.cursor.?);
}

test "pagination: explicit first beyond max errors" {
    const result = pagination.PaginationParams.parse(5000, null, null, null, 100, 1000);
    try testing.expectError(error.LimitExceeded, result);
}

test "pagination: explicit first at max passes" {
    const params = try pagination.PaginationParams.parse(1000, null, null, null, 100, 1000);
    try testing.expectEqual(@as(usize, 1000), params.limit);
}

test "pagination: error for first and last together" {
    const result = pagination.PaginationParams.parse(10, null, 10, null, 100, 1000);
    try testing.expectError(error.InvalidPaginationArgs, result);
}

test "pagination: error for after and before together" {
    const result = pagination.PaginationParams.parse(10, "a", null, "b", 100, 1000);
    try testing.expectError(error.InvalidPaginationArgs, result);
}

test "pagination: error for first with before" {
    const result = pagination.PaginationParams.parse(10, null, null, "cursor", 100, 1000);
    try testing.expectError(error.InvalidPaginationArgs, result);
}

test "pagination: error for last with after" {
    const result = pagination.PaginationParams.parse(null, "cursor", 10, null, 100, 1000);
    try testing.expectError(error.InvalidPaginationArgs, result);
}

test "pagination: error for negative limit" {
    const result = pagination.PaginationParams.parse(-5, null, null, null, 100, 1000);
    try testing.expectError(error.NegativeLimit, result);
}

test "pagination: cursor codec int roundtrip" {
    const allocator = testing.allocator;

    const cursor = try pagination.CursorCodec.encodeInt(allocator, 42);
    defer allocator.free(cursor);

    const decoded = try pagination.CursorCodec.decodeInt(allocator, cursor);
    try testing.expectEqual(@as(i64, 42), decoded);
}

test "pagination: cursor codec string roundtrip" {
    const allocator = testing.allocator;

    const cursor = try pagination.CursorCodec.encodeString(allocator, "test-id-123");
    defer allocator.free(cursor);

    const decoded = try pagination.CursorCodec.decodeString(allocator, cursor);
    defer allocator.free(decoded);

    try testing.expectEqualStrings("test-id-123", decoded);
}
