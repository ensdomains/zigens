/// Schema-driven query validation for incoming GraphQL queries.
///
/// Loads the introspection JSON once at handler-init time and uses it to
/// validate every request before it reaches the executor. Walks every
/// operation's selection set — at every depth, through named and inline
/// fragments — and rejects what used to degrade into silent nulls or
/// silently dropped arguments:
///   1. **Missing required args** — e.g. `domain { name }` (no `id:` on a
///      field declared as `id: String!`).
///   2. **Unknown args** — e.g. `domains(badArg: 1)`, or a nested
///      `subdomains(bogus: 1)`.
///   3. **Unknown fields inside input objects** — e.g.
///      `domains(where: { totallyBogus: 1 })`, at any depth.
///   4. **Unknown fields in a selection set** — e.g. `domains { notAField }`,
///      which used to resolve to null, indistinguishable from a genuine absence.
///   5. **Fragments on the wrong type** — the schema has no interfaces or
///      unions, so a type condition must name the enclosing type exactly.
///
/// The check is purely structural — it doesn't enforce scalar-type
/// agreement (Int vs String etc.) because the runtime arg parser already
/// surfaces type-mismatch as targeted errors (e.g. InvalidAddress).
/// Unknown root fields are left to the executor's `UnknownRootField`, and
/// `__`-prefixed meta fields to introspection.
///
/// Flat-key storage: composite keys like `"Domain.subdomains"` and
/// `"Domain.subdomains.first"` keep ownership simple — one HashMap per kind,
/// freed wholesale in `deinit`. Lookups build the key on the stack.
const std = @import("std");
const parser = @import("../lib/graphql/parser.zig");

/// Last validation failure detail for the CURRENT THREAD — the offending
/// field/argument names plus the byte offset of the offending node, for the
/// client-facing error message and its `locations` entry. Zig errors carry
/// no payload and the validator instance is shared across request threads, so
/// the diagnostic rides in a threadlocal: written at the error site, read by
/// the handler on the same thread immediately after the failed call.
threadlocal var diag_buf: [192]u8 = undefined;
threadlocal var diag_len: usize = 0;
threadlocal var diag_pos: ?usize = null;

fn setDiag(pos: usize, comptime fmt: []const u8, args: anytype) void {
    diag_pos = pos;
    const written = std.fmt.bufPrint(&diag_buf, fmt, args) catch {
        diag_len = 0;
        return;
    };
    diag_len = written.len;
}

/// The current thread's last validation diagnostic, or null. Only meaningful
/// immediately after an error return; call `clearDiag` before validating.
pub fn lastDiagnostic() ?[]const u8 {
    return if (diag_len == 0) null else diag_buf[0..diag_len];
}

/// Byte offset (into the query source) of the node behind the last
/// diagnostic — the handler converts it to the error's line/column.
pub fn lastDiagnosticPos() ?usize {
    return diag_pos;
}

/// Reset the thread's diagnostic so a validation pass can never surface a
/// stale detail from an earlier request on the same thread.
pub fn clearDiag() void {
    diag_len = 0;
    diag_pos = null;
}

pub const SchemaValidator = struct {
    allocator: std.mem.Allocator,

    /// `"{ObjectType}.{field}" → FieldSpec` for every OBJECT type, Query included.
    fields: std.StringHashMap(FieldSpec),
    /// `"{ObjectType}.{field}.{arg}" → ArgSpec` for every declared argument.
    field_args: std.StringHashMap(ArgSpec),
    /// All OBJECT type names: the composite types a selection set can apply to.
    object_types: std.StringHashMap(void),
    /// `"{InputType}.{field}" → ArgSpec` for every (input type, field) pair.
    input_object_fields: std.StringHashMap(ArgSpec),
    /// All input-object type names we know about. If a type name isn't in
    /// here, we skip its validation (can't know what fields are allowed).
    input_object_types_present: std.StringHashMap(void),
    /// Root operation type name, the entry point for selection validation.
    query_type_name: []const u8,

    /// Owned key and name buffers, freed in bulk on deinit.
    owned_keys: std.ArrayList([]u8),
    /// Owned `FieldSpec.required_args` slices.
    owned_lists: std.ArrayList([][]const u8),

    pub const FieldSpec = struct {
        /// Named type the field leads to, list and non-null wrappers stripped.
        type_name: []const u8,
        /// Declared arguments of non-null type.
        required_args: []const []const u8,
    };

    pub const ArgSpec = struct {
        required: bool,
        /// "SCALAR" / "ENUM" / "INPUT_OBJECT" / etc. of the eventual leaf.
        inner_kind: []const u8,
        /// Type name of the eventual leaf, e.g. "DomainFilter".
        inner_type_name: []const u8,
    };

    pub const Error = error{
        MissingRequiredArg,
        UnknownArgument,
        UnknownInputObjectField,
        UnknownField,
        InvalidFragmentType,
        OutOfMemory,
    };

    const KEY_MAX = 512;

    pub fn init(allocator: std.mem.Allocator, introspection_json: []const u8) !SchemaValidator {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, introspection_json, .{});
        defer parsed.deinit();

        const root = parsed.value.object.get("data") orelse return error.OutOfMemory;
        const schema = root.object.get("__schema") orelse return error.OutOfMemory;
        const query_type_name = schema.object.get("queryType").?.object.get("name").?.string;
        const types_arr = schema.object.get("types").?.array;

        var validator = SchemaValidator{
            .allocator = allocator,
            .fields = std.StringHashMap(FieldSpec).init(allocator),
            .field_args = std.StringHashMap(ArgSpec).init(allocator),
            .object_types = std.StringHashMap(void).init(allocator),
            .input_object_fields = std.StringHashMap(ArgSpec).init(allocator),
            .input_object_types_present = std.StringHashMap(void).init(allocator),
            .query_type_name = "",
            .owned_keys = .empty,
            .owned_lists = .empty,
        };
        errdefer validator.deinit();

        validator.query_type_name = try validator.own(query_type_name);

        for (types_arr.items) |type_item| {
            const type_obj = type_item.object;
            const kind = type_obj.get("kind").?.string;
            const name_val = type_obj.get("name") orelse continue;
            if (name_val != .string) continue;
            const type_name = name_val.string;

            if (std.mem.eql(u8, kind, "OBJECT")) {
                try validator.object_types.put(try validator.own(type_name), {});
                const fields_val = type_obj.get("fields") orelse continue;
                if (fields_val != .array) continue;
                for (fields_val.array.items) |field_item| {
                    try validator.addField(type_name, field_item.object);
                }
            } else if (std.mem.eql(u8, kind, "INPUT_OBJECT")) {
                const input_fields = type_obj.get("inputFields") orelse continue;
                if (input_fields != .array) continue;
                try validator.input_object_types_present.put(try validator.own(type_name), {});
                for (input_fields.array.items) |field_item| {
                    const f = field_item.object;
                    const fname = f.get("name").?.string;
                    const spec = parseArgSpec(f.get("type").?, allocator, &validator.owned_keys);
                    const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, fname });
                    try validator.owned_keys.append(allocator, key);
                    try validator.input_object_fields.put(key, spec);
                }
            }
        }
        return validator;
    }

    fn own(self: *SchemaValidator, text: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        try self.owned_keys.append(self.allocator, copy);
        return copy;
    }

    fn addField(self: *SchemaValidator, type_name: []const u8, f: std.json.ObjectMap) !void {
        const fname = f.get("name").?.string;
        // A field with no declared type still exists; an empty child type
        // lets the name validate while recursion stops there.
        const type_val = f.get("type") orelse std.json.Value{ .null = {} };
        const leaf = if (type_val == .object) parseArgSpec(type_val, self.allocator, &self.owned_keys).inner_type_name else "";

        var required: std.ArrayList([]const u8) = .empty;
        defer required.deinit(self.allocator);
        if (f.get("args")) |args_val| {
            if (args_val == .array) {
                for (args_val.array.items) |arg_item| {
                    const a = arg_item.object;
                    const aname = try self.own(a.get("name").?.string);
                    const spec = parseArgSpec(a.get("type").?, self.allocator, &self.owned_keys);
                    const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ type_name, fname, aname });
                    try self.owned_keys.append(self.allocator, key);
                    try self.field_args.put(key, spec);
                    if (spec.required) try required.append(self.allocator, aname);
                }
            }
        }
        const required_owned = try required.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(required_owned);
        try self.owned_lists.append(self.allocator, required_owned);

        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ type_name, fname });
        try self.owned_keys.append(self.allocator, key);
        try self.fields.put(key, .{ .type_name = leaf, .required_args = required_owned });
    }

    pub fn deinit(self: *SchemaValidator) void {
        self.fields.deinit();
        self.field_args.deinit();
        self.object_types.deinit();
        self.input_object_fields.deinit();
        self.input_object_types_present.deinit();
        for (self.owned_keys.items) |k| self.allocator.free(k);
        self.owned_keys.deinit(self.allocator);
        for (self.owned_lists.items) |l| self.allocator.free(l);
        self.owned_lists.deinit(self.allocator);
    }

    /// Validate one operation's whole selection set. `allocator` backs the
    /// per-call fragment memo (the validator itself is shared across threads).
    pub fn validateOperation(self: *const SchemaValidator, allocator: std.mem.Allocator, operation: *const parser.Operation, fragments: []const parser.Fragment) Error!void {
        var walk = Walk{ .validator = self, .fragments = fragments, .validated = std.StringHashMap(void).init(allocator) };
        defer walk.validated.deinit();
        try walk.selectionSet(self.query_type_name, operation.fields);
    }

    const Walk = struct {
        validator: *const SchemaValidator,
        fragments: []const parser.Fragment,
        /// Named fragments already walked. A fragment's type condition is
        /// fixed, so its body only needs checking once per operation; each
        /// spread site still checks that the condition fits where it is used.
        validated: std.StringHashMap(void),

        fn selectionSet(self: *Walk, type_name: []const u8, selections: []const parser.Field) Error!void {
            for (selections) |*sel| {
                if (sel.fragment_spread) |frag_name| {
                    // Undefined fragments are rejected earlier (query_validator).
                    const frag = self.findFragment(frag_name) orelse continue;
                    try self.typeCondition(type_name, frag.type_condition, sel.pos);
                    const gop = try self.validated.getOrPut(frag.name);
                    if (gop.found_existing) continue;
                    try self.selectionSet(frag.type_condition, frag.selections);
                    continue;
                }
                if (sel.inline_fragment) {
                    try self.typeCondition(type_name, sel.name, sel.pos);
                    try self.selectionSet(type_name, sel.selections);
                    continue;
                }
                try self.field(type_name, sel);
            }
        }

        fn field(self: *Walk, type_name: []const u8, sel: *const parser.Field) Error!void {
            if (std.mem.startsWith(u8, sel.name, "__")) return;
            const v = self.validator;
            const is_root = std.mem.eql(u8, type_name, v.query_type_name);

            var key_buf: [KEY_MAX]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ type_name, sel.name }) catch null;
            const spec = (if (key) |k| v.fields.get(k) else null) orelse {
                if (is_root) return;
                std.log.warn("schema validation: `{s}` has no field `{s}`", .{ type_name, sel.name });
                setDiag(sel.pos, "`{s}` has no field `{s}`", .{ type_name, sel.name });
                return error.UnknownField;
            };

            for (sel.arguments) |arg| {
                var arg_buf: [KEY_MAX]u8 = undefined;
                const arg_key = std.fmt.bufPrint(&arg_buf, "{s}.{s}.{s}", .{ type_name, sel.name, arg.name }) catch null;
                const arg_spec = (if (arg_key) |k| v.field_args.get(k) else null) orelse {
                    std.log.warn("schema validation: `{s}.{s}` got unknown arg `{s}`", .{ type_name, sel.name, arg.name });
                    if (is_root) {
                        setDiag(arg.pos, "`{s}` has no argument `{s}`", .{ sel.name, arg.name });
                    } else {
                        setDiag(arg.pos, "`{s}.{s}` has no argument `{s}`", .{ type_name, sel.name, arg.name });
                    }
                    return error.UnknownArgument;
                };
                try v.validateInputValue(arg_spec.inner_type_name, arg.value, arg.pos);
            }
            for (spec.required_args) |arg_name| {
                if (hasArg(sel, arg_name)) continue;
                std.log.warn("schema validation: `{s}.{s}` requires arg `{s}`", .{ type_name, sel.name, arg_name });
                if (is_root) {
                    setDiag(sel.pos, "`{s}` requires argument `{s}`", .{ sel.name, arg_name });
                } else {
                    setDiag(sel.pos, "`{s}.{s}` requires argument `{s}`", .{ type_name, sel.name, arg_name });
                }
                return error.MissingRequiredArg;
            }

            // A subselection on a scalar is left to the executor, whose
            // SubSelectionOnScalar message says more than "unknown field".
            if (sel.selections.len > 0 and v.object_types.contains(spec.type_name)) {
                try self.selectionSet(spec.type_name, sel.selections);
            }
        }

        fn typeCondition(self: *Walk, enclosing: []const u8, condition: []const u8, pos: usize) Error!void {
            if (std.mem.eql(u8, enclosing, condition)) return;
            if (!self.validator.object_types.contains(condition)) {
                setDiag(pos, "unknown type `{s}` in a fragment type condition", .{condition});
            } else {
                setDiag(pos, "a fragment on `{s}` cannot be spread where `{s}` is expected", .{ condition, enclosing });
            }
            return error.InvalidFragmentType;
        }

        fn findFragment(self: *Walk, name: []const u8) ?*const parser.Fragment {
            for (self.fragments) |*frag| {
                if (std.mem.eql(u8, frag.name, name)) return frag;
            }
            return null;
        }
    };

    /// An argument value against its declared type: input objects are checked
    /// field by field, including inside lists (`where: { or: [ { … } ] }`).
    fn validateInputValue(self: *const SchemaValidator, type_name: []const u8, value: parser.Value, pos: usize) Error!void {
        switch (value) {
            .object => |obj| try self.validateInputObject(type_name, obj, pos),
            .list => |items| for (items) |item| try self.validateInputValue(type_name, item, pos),
            else => {},
        }
    }

    /// `ctx_pos` — byte offset of the argument/field that holds this input
    /// object; anchors the missing-required-field error, which has no node
    /// of its own to point at.
    fn validateInputObject(self: *const SchemaValidator, type_name: []const u8, args: []parser.Argument, ctx_pos: usize) Error!void {
        if (!self.input_object_types_present.contains(type_name)) return;

        for (args) |a| {
            var key_buf: [KEY_MAX]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ type_name, a.name }) catch null;
            const spec = (if (key) |k| self.input_object_fields.get(k) else null) orelse {
                std.log.warn("validateInputObject: `{s}` has no field `{s}`", .{ type_name, a.name });
                setDiag(a.pos, "`{s}` has no field `{s}`", .{ type_name, a.name });
                return error.UnknownInputObjectField;
            };
            try self.validateInputValue(spec.inner_type_name, a.value, a.pos);
        }

        var prefix_buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}.", .{type_name}) catch return;
        var it = self.input_object_fields.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, key, prefix)) continue;
            if (!entry.value_ptr.required) continue;
            const field_name = key[prefix.len..];
            var found = false;
            for (args) |a| {
                if (std.mem.eql(u8, a.name, field_name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                setDiag(ctx_pos, "`{s}` requires field `{s}`", .{ type_name, field_name });
                return error.MissingRequiredArg;
            }
        }
    }
};

fn hasArg(field: *const parser.Field, name: []const u8) bool {
    for (field.arguments) |a| {
        if (std.mem.eql(u8, a.name, name)) return true;
    }
    return false;
}

/// Pulls the `(required, inner_kind, inner_type_name)` triple out of a type
/// shape. NON_NULL wraps the next layer; LIST also wraps but we don't care
/// about list-of-X distinction at this layer (the runtime arg parser handles
/// list shape). What matters is the eventual leaf kind/name.
///
/// `inner_type_name` is dup'd onto the validator's owned-keys list so the
/// returned slice remains valid after the input JSON is freed.
fn parseArgSpec(type_val: std.json.Value, allocator: std.mem.Allocator, owned_keys: *std.ArrayList([]u8)) SchemaValidator.ArgSpec {
    var required = false;
    var cur = type_val;
    if (std.mem.eql(u8, cur.object.get("kind").?.string, "NON_NULL")) {
        required = true;
        cur = cur.object.get("ofType").?;
    }
    while (std.mem.eql(u8, cur.object.get("kind").?.string, "LIST")) {
        cur = cur.object.get("ofType").?;
        if (std.mem.eql(u8, cur.object.get("kind").?.string, "NON_NULL")) {
            cur = cur.object.get("ofType").?;
        }
    }
    const kind_str = cur.object.get("kind").?.string;
    const name_val = cur.object.get("name") orelse std.json.Value{ .string = "" };
    const name_str = if (name_val == .string) name_val.string else "";

    // Dup both onto owned_keys so the slices outlive the parsed JSON. If
    // these allocations fail we return defaults — the worst case is a missed
    // validation, never a corruption.
    const kind_owned = allocator.dupe(u8, kind_str) catch return .{ .required = required, .inner_kind = "", .inner_type_name = "" };
    owned_keys.append(allocator, kind_owned) catch return .{ .required = required, .inner_kind = "", .inner_type_name = "" };
    const name_owned = allocator.dupe(u8, name_str) catch return .{ .required = required, .inner_kind = kind_owned, .inner_type_name = "" };
    owned_keys.append(allocator, name_owned) catch return .{ .required = required, .inner_kind = kind_owned, .inner_type_name = "" };
    return .{
        .required = required,
        .inner_kind = kind_owned,
        .inner_type_name = name_owned,
    };
}

const testing = std.testing;

// Minimal introspection: `thing(id: String!, where: ThingFilter)` returning
// Thing, whose nested fields carry arguments of their own; ThingFilter
// declares `ok: Int`, `must: Int!` and a recursive `or: [ThingFilter!]`.
const TEST_INTROSPECTION =
    \\{"data":{"__schema":{"queryType":{"name":"Query"},"types":[
    \\{"kind":"OBJECT","name":"Query","fields":[
    \\{"name":"thing","type":{"kind":"OBJECT","name":"Thing"},"args":[
    \\{"name":"id","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String"}}},
    \\{"name":"where","type":{"kind":"INPUT_OBJECT","name":"ThingFilter"}}]}]},
    \\{"kind":"OBJECT","name":"Thing","fields":[
    \\{"name":"id","type":{"kind":"SCALAR","name":"String"},"args":[]},
    \\{"name":"texts","type":{"kind":"LIST","name":null,"ofType":{"kind":"SCALAR","name":"String"}},"args":[]},
    \\{"name":"text","type":{"kind":"SCALAR","name":"String"},"args":[
    \\{"name":"key","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String"}}}]},
    \\{"name":"children","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"LIST","name":null,"ofType":{"kind":"OBJECT","name":"Thing"}}},"args":[
    \\{"name":"first","type":{"kind":"SCALAR","name":"Int"}},
    \\{"name":"where","type":{"kind":"INPUT_OBJECT","name":"ThingFilter"}}]},
    \\{"name":"child","type":{"kind":"OBJECT","name":"Thing"},"args":[]}]},
    \\{"kind":"OBJECT","name":"Other","fields":[
    \\{"name":"id","type":{"kind":"SCALAR","name":"String"},"args":[]}]},
    \\{"kind":"INPUT_OBJECT","name":"ThingFilter","inputFields":[
    \\{"name":"ok","type":{"kind":"SCALAR","name":"Int"}},
    \\{"name":"or","type":{"kind":"LIST","name":null,"ofType":{"kind":"NON_NULL","name":null,"ofType":{"kind":"INPUT_OBJECT","name":"ThingFilter"}}}},
    \\{"name":"must","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"Int"}}}]}
    \\]}}}
;

fn validate(query: []const u8) !void {
    var validator = try SchemaValidator.init(testing.allocator, TEST_INTROSPECTION);
    defer validator.deinit();
    var doc = try parser.parseQuery(testing.allocator, query);
    defer doc.deinit(testing.allocator);
    clearDiag();
    for (doc.operations) |*op| try validator.validateOperation(testing.allocator, op, doc.fragments);
}

// Assert the error, the diagnostic text, and that the diagnostic position
// lands on `anchor` (its first occurrence in the query source).
fn expectDiag(query: []const u8, expected_err: anyerror, expected_text: []const u8, anchor: []const u8) !void {
    try testing.expectError(expected_err, validate(query));
    try testing.expectEqualStrings(expected_text, lastDiagnostic().?);
    try testing.expectEqual(std.mem.indexOf(u8, query, anchor).?, lastDiagnosticPos().?);
}

fn expectOk(query: []const u8) !void {
    try validate(query);
    try testing.expect(lastDiagnostic() == null);
    try testing.expectEqual(@as(?usize, null), lastDiagnosticPos());
}

test "unknown argument: diagnostic names it and anchors at the argument" {
    try expectDiag("{ thing(id: \"x\", nope: 1) { id } }", error.UnknownArgument, "`thing` has no argument `nope`", "nope");
}

test "missing required root argument: anchors at the field" {
    try expectDiag("{ thing(where: {ok: 1, must: 2}) { id } }", error.MissingRequiredArg, "`thing` requires argument `id`", "thing");
}

test "unknown input-object field: anchors at the offending field" {
    try expectDiag("{ thing(id: \"x\", where: {bogus: 1, must: 2}) { id } }", error.UnknownInputObjectField, "`ThingFilter` has no field `bogus`", "bogus");
}

test "missing required input-object field: anchors at the enclosing argument" {
    try expectDiag("{ thing(id: \"x\", where: {ok: 1}) { id } }", error.MissingRequiredArg, "`ThingFilter` requires field `must`", "where");
}

test "input objects inside lists are checked" {
    try expectDiag("{ thing(id: \"x\", where: {must: 1, or: [{must: 2}, {must: 3, bogus: 4}]}) { id } }", error.UnknownInputObjectField, "`ThingFilter` has no field `bogus`", "bogus");
}

test "valid query leaves no diagnostic" {
    try expectOk("{ thing(id: \"x\", where: {ok: 1, must: 2, or: [{must: 3}]}) { id } }");
}

test "unknown selection field: names the type and anchors at the field" {
    try expectDiag("{ thing(id: \"x\") { nope } }", error.UnknownField, "`Thing` has no field `nope`", "nope");
}

test "unknown selection field is caught at depth" {
    try expectDiag("{ thing(id: \"x\") { child { child { nope } } } }", error.UnknownField, "`Thing` has no field `nope`", "nope");
}

test "nested arguments get the same checks as root arguments" {
    // The same typo must not be a 400 at the root and a silently dropped
    // filter one level down.
    try expectDiag("{ thing(id: \"x\") { children(bogus: 1) { id } } }", error.UnknownArgument, "`Thing.children` has no argument `bogus`", "bogus");
    try expectDiag("{ thing(id: \"x\") { children(where: {must: 1, bogus: 2}) { id } } }", error.UnknownInputObjectField, "`ThingFilter` has no field `bogus`", "bogus");
    try expectDiag("{ thing(id: \"x\") { child { text } } }", error.MissingRequiredArg, "`Thing.text` requires argument `key`", "text");
    try expectOk("{ thing(id: \"x\") { children(first: 2, where: {must: 1}) { text(key: \"k\") } } }");
}

test "unknown field inside a named fragment is caught against its type condition" {
    try expectDiag("query Q { thing(id: \"x\") { ...F } } fragment F on Thing { nope }", error.UnknownField, "`Thing` has no field `nope`", "nope");
}

test "root-level fragment spreads are validated" {
    try expectDiag("query Q { ...Root } fragment Root on Query { thing(id: \"x\") { nope } }", error.UnknownField, "`Thing` has no field `nope`", "nope");
    try expectDiag("query Q { ...Root } fragment Root on Query { thing { id } }", error.MissingRequiredArg, "`thing` requires argument `id`", "thing {");
    try expectOk("query Q { ...Root } fragment Root on Query { thing(id: \"x\") { id } }");
}

test "a fragment named after a root field is not mistaken for that field" {
    try expectOk("query Q { ...thing } fragment thing on Query { thing(id: \"x\") { id } }");
}

test "fragment type conditions must name the enclosing type" {
    try expectDiag("{ thing(id: \"x\") { ... on Other { id } } }", error.InvalidFragmentType, "a fragment on `Other` cannot be spread where `Thing` is expected", "...");
    try expectDiag("query Q { thing(id: \"x\") { ...F } } fragment F on Other { id }", error.InvalidFragmentType, "a fragment on `Other` cannot be spread where `Thing` is expected", "...F");
    try expectDiag("{ thing(id: \"x\") { ... on Nope { id } } }", error.InvalidFragmentType, "unknown type `Nope` in a fragment type condition", "...");
}

test "valid selections pass: nesting, aliases, __typename, fragments" {
    try expectOk("{ thing(id: \"x\") { id child { id } } }");
    try expectOk("{ thing(id: \"x\") { __typename alias: id } }");
    try expectOk("query Q { thing(id: \"x\") { ...F child { ...F } } } fragment F on Thing { id child { id } }");
    try expectOk("{ thing(id: \"x\") { ... on Thing { id } } }");
    // An inline fragment is recognised by the parser, not guessed from its
    // name, so an empty one is fine too.
    try expectOk("{ thing(id: \"x\") { id ... on Thing { } } }");
}

test "a subselection on a scalar is left to the executor, not reported as unknown" {
    // SubSelectionOnScalar carries a better message than "unknown field".
    try expectOk("{ thing(id: \"x\") { texts { key } } }");
}

test "an unknown root field is left to the executor" {
    // UnknownRootField has its own error text.
    try expectOk("{ notARealRootField { nope } }");
}

test "an overlong field name is reported as unknown, not truncated into a match" {
    const long = "a" ** 600;
    try testing.expectError(error.UnknownField, validate("{ thing(id: \"x\") { " ++ long ++ " } }"));
}
