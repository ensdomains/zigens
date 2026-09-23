/// Schema-driven argument validation for incoming GraphQL queries.
///
/// Loads the introspection JSON once at handler-init time and uses it to
/// validate every request before it reaches the executor. Catches three
/// classes of bug that previously slipped through and degraded into
/// silent-null results:
///   1. **Missing required args** — e.g. `domain { name }` (no `id:` on a
///      field declared as `id: String!`).
///   2. **Unknown args on root fields** — e.g. `domains(badArg: 1)`.
///   3. **Unknown fields inside input objects** — e.g.
///      `domains(where: { totallyBogus: 1 })`. This generalizes the manual
///      `UnknownFilterArg` check we had to thread through each resolver.
///
/// The check is purely structural — it doesn't enforce scalar-type
/// agreement (Int vs String etc.) because the runtime arg parser already
/// surfaces type-mismatch as targeted errors (e.g. InvalidAddress).
///
/// Flat-key storage: composite keys like `"Query.domains.first"` and
/// `"DomainFilter.name_in"` keep ownership simple — one HashMap per kind,
/// freed wholesale in `deinit`. An earlier nested-HashMap version leaked
/// buckets on test teardown, so we keep it flat for clarity.
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

    /// `"{root_field}.{arg}" → ArgSpec` for every (root field, arg) pair.
    root_field_args: std.StringHashMap(ArgSpec),
    /// All root-field names that *have at least one declared arg* — used
    /// to know whether to also validate against `root_field_args`.
    root_fields_present: std.StringHashMap(void),
    /// `"{InputType}.{field}" → ArgSpec` for every (input type, field) pair.
    input_object_fields: std.StringHashMap(ArgSpec),
    /// All input-object type names we know about. If a type name isn't in
    /// here, we skip its validation (can't know what fields are allowed).
    input_object_types_present: std.StringHashMap(void),

    /// Owned key buffers. Composite keys live on the heap (we allocPrint
    /// them); freeing happens in bulk on deinit.
    owned_keys: std.ArrayList([]u8),

    pub const ArgSpec = struct {
        required: bool,
        /// "SCALAR" / "ENUM" / "LIST" / "INPUT_OBJECT" / etc. — we only act
        /// on INPUT_OBJECT to know whether to recurse.
        inner_kind: []const u8,
        /// Type name of the eventual leaf, e.g. "DomainFilter".
        inner_type_name: []const u8,
    };

    pub const Error = error{
        MissingRequiredArg,
        UnknownArgument,
        UnknownInputObjectField,
        OutOfMemory,
    };

    pub fn init(allocator: std.mem.Allocator, introspection_json: []const u8) !SchemaValidator {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, introspection_json, .{});
        defer parsed.deinit();

        const root = parsed.value.object.get("data") orelse return error.OutOfMemory;
        const schema = root.object.get("__schema") orelse return error.OutOfMemory;
        const query_type_name = schema.object.get("queryType").?.object.get("name").?.string;
        const types_arr = schema.object.get("types").?.array;

        var validator = SchemaValidator{
            .allocator = allocator,
            .root_field_args = std.StringHashMap(ArgSpec).init(allocator),
            .root_fields_present = std.StringHashMap(void).init(allocator),
            .input_object_fields = std.StringHashMap(ArgSpec).init(allocator),
            .input_object_types_present = std.StringHashMap(void).init(allocator),
            .owned_keys = .empty,
        };
        errdefer validator.deinit();

        for (types_arr.items) |type_item| {
            const type_obj = type_item.object;
            const kind = type_obj.get("kind").?.string;
            const name_val = type_obj.get("name") orelse continue;
            if (name_val != .string) continue;
            const type_name = name_val.string;

            if (std.mem.eql(u8, kind, "OBJECT") and std.mem.eql(u8, type_name, query_type_name)) {
                const fields = type_obj.get("fields").?.array;
                for (fields.items) |field_item| {
                    const f = field_item.object;
                    const fname = f.get("name").?.string;
                    // Track that this root field exists with at least the
                    // ability to receive args (even if zero args declared).
                    const field_key = try allocator.dupe(u8, fname);
                    try validator.owned_keys.append(allocator, field_key);
                    try validator.root_fields_present.put(field_key, {});
                    const args = f.get("args").?.array;
                    for (args.items) |arg_item| {
                        const a = arg_item.object;
                        const aname = a.get("name").?.string;
                        const spec = parseArgSpec(a.get("type").?, allocator, &validator.owned_keys);
                        const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ fname, aname });
                        try validator.owned_keys.append(allocator, key);
                        try validator.root_field_args.put(key, spec);
                    }
                }
            } else if (std.mem.eql(u8, kind, "INPUT_OBJECT")) {
                const input_fields = type_obj.get("inputFields") orelse continue;
                if (input_fields != .array) continue;
                const type_key = try allocator.dupe(u8, type_name);
                try validator.owned_keys.append(allocator, type_key);
                try validator.input_object_types_present.put(type_key, {});
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

    pub fn deinit(self: *SchemaValidator) void {
        self.root_field_args.deinit();
        self.root_fields_present.deinit();
        self.input_object_fields.deinit();
        self.input_object_types_present.deinit();
        for (self.owned_keys.items) |k| self.allocator.free(k);
        self.owned_keys.deinit(self.allocator);
    }

    /// Validates one root field selection. Skips meta fields (`__typename` etc.)
    /// and unknown root field names (those are surfaced separately by the
    /// executor as `UnknownRootField`).
    pub fn validateRootField(self: *SchemaValidator, field: *const parser.Field) Error!void {
        if (std.mem.startsWith(u8, field.name, "__")) return;
        if (!self.root_fields_present.contains(field.name)) return;

        // Each present arg: declared on the root field?
        for (field.arguments) |arg| {
            const composite = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ field.name, arg.name });
            defer self.allocator.free(composite);
            const spec = self.root_field_args.get(composite) orelse {
                std.log.warn("validateRootField: `{s}` got unknown arg `{s}`", .{ field.name, arg.name });
                setDiag(arg.pos, "`{s}` has no argument `{s}`", .{ field.name, arg.name });
                return error.UnknownArgument;
            };
            if (arg.value == .object) {
                try self.validateInputObject(spec.inner_type_name, arg.value.object, arg.pos);
            }
        }

        // Required args: each schema-required arg present?
        var prefix_buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}.", .{field.name}) catch return;
        var it = self.root_field_args.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, key, prefix)) continue;
            if (!entry.value_ptr.required) continue;
            const arg_name = key[prefix.len..];
            if (!hasArg(field, arg_name)) {
                std.log.warn("validateRootField: `{s}` requires arg `{s}`", .{ field.name, arg_name });
                setDiag(field.pos, "`{s}` requires argument `{s}`", .{ field.name, arg_name });
                return error.MissingRequiredArg;
            }
        }
    }

    /// `ctx_pos` — byte offset of the argument/field that holds this input
    /// object; anchors the missing-required-field error, which has no node
    /// of its own to point at.
    fn validateInputObject(self: *SchemaValidator, type_name: []const u8, args: []parser.Argument, ctx_pos: usize) Error!void {
        if (!self.input_object_types_present.contains(type_name)) return;

        for (args) |a| {
            const composite = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ type_name, a.name });
            defer self.allocator.free(composite);
            const spec = self.input_object_fields.get(composite) orelse {
                std.log.warn("validateInputObject: `{s}` has no field `{s}`", .{ type_name, a.name });
                setDiag(a.pos, "`{s}` has no field `{s}`", .{ type_name, a.name });
                return error.UnknownInputObjectField;
            };
            if (a.value == .object) {
                try self.validateInputObject(spec.inner_type_name, a.value.object, a.pos);
            }
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

// Minimal introspection: `thing(id: String!, where: ThingFilter)` where
// ThingFilter declares `ok: Int` and `must: Int!` — enough to drive all four
// diagnostic paths without depending on the real schema.
const TEST_INTROSPECTION =
    \\{"data":{"__schema":{"queryType":{"name":"Query"},"types":[
    \\{"kind":"OBJECT","name":"Query","fields":[
    \\{"name":"thing","args":[
    \\{"name":"id","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String"}}},
    \\{"name":"where","type":{"kind":"INPUT_OBJECT","name":"ThingFilter"}}]}]},
    \\{"kind":"INPUT_OBJECT","name":"ThingFilter","inputFields":[
    \\{"name":"ok","type":{"kind":"SCALAR","name":"Int"}},
    \\{"name":"must","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"Int"}}}]}
    \\]}}}
;

// Validate `query` against TEST_INTROSPECTION and assert the error, the
// diagnostic text, and that the diagnostic position lands on `anchor`
// (its first occurrence in the query source).
fn expectDiag(query: []const u8, expected_err: anyerror, expected_text: []const u8, anchor: []const u8) !void {
    var validator = try SchemaValidator.init(testing.allocator, TEST_INTROSPECTION);
    defer validator.deinit();
    var doc = try parser.parseQuery(testing.allocator, query);
    defer doc.deinit(testing.allocator);
    clearDiag();
    try testing.expectError(expected_err, validator.validateRootField(&doc.operations[0].fields[0]));
    try testing.expectEqualStrings(expected_text, lastDiagnostic().?);
    try testing.expectEqual(std.mem.indexOf(u8, query, anchor).?, lastDiagnosticPos().?);
}

test "unknown argument: diagnostic names it and anchors at the argument" {
    try expectDiag(
        "{ thing(id: \"x\", nope: 1) { id } }",
        error.UnknownArgument,
        "`thing` has no argument `nope`",
        "nope",
    );
}

test "missing required root argument: anchors at the field" {
    try expectDiag(
        "{ thing(where: {ok: 1, must: 2}) { id } }",
        error.MissingRequiredArg,
        "`thing` requires argument `id`",
        "thing",
    );
}

test "unknown input-object field: anchors at the offending field" {
    try expectDiag(
        "{ thing(id: \"x\", where: {bogus: 1, must: 2}) { id } }",
        error.UnknownInputObjectField,
        "`ThingFilter` has no field `bogus`",
        "bogus",
    );
}

test "missing required input-object field: anchors at the enclosing argument" {
    try expectDiag(
        "{ thing(id: \"x\", where: {ok: 1}) { id } }",
        error.MissingRequiredArg,
        "`ThingFilter` requires field `must`",
        "where",
    );
}

test "valid query leaves no diagnostic" {
    var validator = try SchemaValidator.init(testing.allocator, TEST_INTROSPECTION);
    defer validator.deinit();
    var doc = try parser.parseQuery(testing.allocator, "{ thing(id: \"x\", where: {ok: 1, must: 2}) { id } }");
    defer doc.deinit(testing.allocator);
    clearDiag();
    try validator.validateRootField(&doc.operations[0].fields[0]);
    try testing.expect(lastDiagnostic() == null);
    try testing.expectEqual(@as(?usize, null), lastDiagnosticPos());
}
