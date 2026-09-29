//! Selection-aware projection of the static introspection document.
//!
//! `introspection.json` is generated from schema.graphql at build time and holds
//! the complete `__schema` object. Clients rarely want all of it: GraphiQL asks
//! for `types { ... }` through fragments, portals ask `queryType { fields { name } }`,
//! scripts alias `__type`. Serving the whole document regardless of the selection
//! set made those shapes come back empty or under the wrong key. This walks the
//! requested selections (fields, aliases, `__typename`, named and inline fragments)
//! over the parsed document and writes only what was asked for. `queryType` /
//! `mutationType` / `subscriptionType` are stored as bare `{ name }` references
//! and are expanded to the full type when the selection needs more than the name.
const std = @import("std");
const parser = @import("../lib/graphql/parser.zig");

pub const ProjectError = error{OutOfMemory};

pub const Context = struct {
    allocator: std.mem.Allocator,
    /// `__schema.types` items, used to expand root-type references.
    types: []const std.json.Value,
    fragments: []const parser.Fragment,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The introspection type reached through `field` of `parent` (drives `__typename`).
fn childTypeName(parent: []const u8, field: []const u8) []const u8 {
    if (eql(parent, "__Schema")) return if (eql(field, "directives")) "__Directive" else "__Type";
    if (eql(parent, "__Type")) {
        if (eql(field, "fields")) return "__Field";
        if (eql(field, "inputFields")) return "__InputValue";
        if (eql(field, "enumValues")) return "__EnumValue";
        return "__Type";
    }
    if (eql(parent, "__Field")) return if (eql(field, "args")) "__InputValue" else "__Type";
    if (eql(parent, "__Directive")) return "__InputValue";
    return "__Type";
}

fn isRootTypeRef(parent: []const u8, field: []const u8) bool {
    return eql(parent, "__Schema") and (eql(field, "queryType") or eql(field, "mutationType") or eql(field, "subscriptionType"));
}

fn findFragment(ctx: Context, name: []const u8) ?*const parser.Fragment {
    for (ctx.fragments) |*f| if (eql(f.name, name)) return f;
    return null;
}

/// Full `__Type` object for `name`, or null when the document has no such type.
pub fn findType(ctx: Context, name: []const u8) ?std.json.Value {
    for (ctx.types) |t| {
        if (t != .object) continue;
        const n = t.object.get("name") orelse continue;
        if (n == .string and eql(n.string, name)) return t;
    }
    return null;
}

fn isFragmentLike(field: *const parser.Field) bool {
    return field.fragment_spread != null or field.inline_fragment;
}

/// True when the selection asks for anything beyond `name` / `__typename`
/// (fragments included), i.e. a bare `{ name }` reference is not enough.
fn needsExpansion(ctx: Context, selections: []const parser.Field) bool {
    for (selections) |*sel| {
        if (sel.fragment_spread) |frag_name| {
            if (findFragment(ctx, frag_name)) |frag| {
                if (needsExpansion(ctx, frag.selections)) return true;
            }
            continue;
        }
        if (isFragmentLike(sel)) {
            if (needsExpansion(ctx, sel.selections)) return true;
            continue;
        }
        if (!eql(sel.name, "name") and !eql(sel.name, "__typename")) return true;
    }
    return false;
}

fn writeRaw(ctx: Context, out: *std.ArrayList(u8), value: std.json.Value) ProjectError!void {
    const text = try std.json.Stringify.valueAlloc(ctx.allocator, value, .{});
    defer ctx.allocator.free(text);
    try out.appendSlice(ctx.allocator, text);
}

fn writeString(ctx: Context, out: *std.ArrayList(u8), s: []const u8) ProjectError!void {
    try writeRaw(ctx, out, .{ .string = s });
}

/// Write `value` narrowed to `selections`. An empty selection set writes the
/// value untouched (lenient, matching the previous whole-document behavior).
pub fn writeProjected(ctx: Context, out: *std.ArrayList(u8), value: std.json.Value, selections: []const parser.Field, type_name: []const u8) ProjectError!void {
    if (selections.len == 0) return writeRaw(ctx, out, value);
    switch (value) {
        .null => try out.appendSlice(ctx.allocator, "null"),
        .array => |items| {
            try out.append(ctx.allocator, '[');
            for (items.items, 0..) |item, i| {
                if (i > 0) try out.append(ctx.allocator, ',');
                try writeProjected(ctx, out, item, selections, type_name);
            }
            try out.append(ctx.allocator, ']');
        },
        .object => |obj| {
            try out.append(ctx.allocator, '{');
            var first = true;
            try writeObjectFields(ctx, out, obj, selections, type_name, &first);
            try out.append(ctx.allocator, '}');
        },
        else => try writeRaw(ctx, out, value),
    }
}

fn writeObjectFields(ctx: Context, out: *std.ArrayList(u8), obj: std.json.ObjectMap, selections: []const parser.Field, type_name: []const u8, first: *bool) ProjectError!void {
    for (selections) |*sel| {
        if (sel.fragment_spread) |frag_name| {
            const frag = findFragment(ctx, frag_name) orelse continue;
            try writeObjectFields(ctx, out, obj, frag.selections, type_name, first);
            continue;
        }
        if (isFragmentLike(sel)) {
            try writeObjectFields(ctx, out, obj, sel.selections, type_name, first);
            continue;
        }
        if (!first.*) try out.append(ctx.allocator, ',');
        first.* = false;
        try writeString(ctx, out, sel.alias orelse sel.name);
        try out.append(ctx.allocator, ':');

        if (eql(sel.name, "__typename")) {
            try writeString(ctx, out, type_name);
            continue;
        }
        var child: std.json.Value = obj.get(sel.name) orelse .null;
        if (child == .object and isRootTypeRef(type_name, sel.name) and needsExpansion(ctx, sel.selections)) {
            if (child.object.get("name")) |ref_name| {
                if (ref_name == .string) child = findType(ctx, ref_name.string) orelse child;
            }
        }
        try writeProjected(ctx, out, child, sel.selections, childTypeName(type_name, sel.name));
    }
}

// ============================================================================
// Tests
// ============================================================================

const SAMPLE =
    \\{"data":{"__schema":{"queryType":{"name":"Query"},"mutationType":null,
    \\"types":[{"kind":"OBJECT","name":"Query","fields":[{"name":"domain","args":[{"name":"id","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String"}}}],"type":{"kind":"OBJECT","name":"Domain","ofType":null}}]},
    \\{"kind":"OBJECT","name":"Domain","fields":[{"name":"id","args":[],"type":{"kind":"SCALAR","name":"String","ofType":null}}]}],
    \\"directives":[]}}}
;

fn projectQuery(allocator: std.mem.Allocator, query: []const u8, root_index: usize) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, SAMPLE, .{});
    defer parsed.deinit();
    const schema = parsed.value.object.get("data").?.object.get("__schema").?;
    var document = try parser.parseQuery(allocator, query);
    defer document.deinit(allocator);
    const ctx = Context{ .allocator = allocator, .types = schema.object.get("types").?.array.items, .fragments = document.fragments };
    const root = &document.operations[0].fields[root_index];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (eql(root.name, "__schema")) {
        try writeProjected(ctx, &out, schema, root.selections, "__Schema");
    } else {
        const type_name = parser.getStringArg(root, "name", null).?;
        try writeProjected(ctx, &out, findType(ctx, type_name) orelse .null, root.selections, "__Type");
    }
    return out.toOwnedSlice(allocator);
}

test "queryType expands to the full type when fields are requested" {
    const a = std.testing.allocator;
    const got = try projectQuery(a, "{ __schema { queryType { name fields { name } } } }", 0);
    defer a.free(got);
    try std.testing.expectEqualStrings("{\"queryType\":{\"name\":\"Query\",\"fields\":[{\"name\":\"domain\"}]}}", got);
}

test "queryType stays a bare name reference when only name is asked" {
    const a = std.testing.allocator;
    const got = try projectQuery(a, "{ __schema { queryType { name } mutationType { name } } }", 0);
    defer a.free(got);
    try std.testing.expectEqualStrings("{\"queryType\":{\"name\":\"Query\"},\"mutationType\":null}", got);
}

test "aliases, __typename, nested lists and missing fields" {
    const a = std.testing.allocator;
    const got = try projectQuery(a, "{ __type(name: \"Query\") { __typename n: name fields { name args { name type { kind ofType { name } } } description } } }", 0);
    defer a.free(got);
    try std.testing.expectEqualStrings("{\"__typename\":\"__Type\",\"n\":\"Query\",\"fields\":[{\"name\":\"domain\",\"args\":[{\"name\":\"id\",\"type\":{\"kind\":\"NON_NULL\",\"ofType\":{\"name\":\"String\"}}}],\"description\":null}]}", got);
}

test "named and inline fragments are expanded in place" {
    const a = std.testing.allocator;
    const got = try projectQuery(a, "query Q { __schema { types { ...T ... on __Type { kind } } } } fragment T on __Type { name }", 0);
    defer a.free(got);
    try std.testing.expectEqualStrings("{\"types\":[{\"name\":\"Query\",\"kind\":\"OBJECT\"},{\"name\":\"Domain\",\"kind\":\"OBJECT\"}]}", got);
}

test "unknown type projects to null and empty selection writes the raw value" {
    const a = std.testing.allocator;
    const got = try projectQuery(a, "{ __type(name: \"Nope\") { name } }", 0);
    defer a.free(got);
    try std.testing.expectEqualStrings("null", got);
    const raw = try projectQuery(a, "{ __schema { mutationType } }", 0);
    defer a.free(raw);
    try std.testing.expectEqualStrings("{\"mutationType\":null}", raw);
}
