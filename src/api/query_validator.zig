//! Structural validation pass between parse and execution.
//!
//! GraphQL fragment spreads form a directed graph; the spec forbids cycles
//! (a cyclic fragment can never terminate). The complexity analyzer
//! (`complexity.analyzeField`) and the executor (`Executor.expandSelections`)
//! BOTH expand named spreads by recursing into the referenced fragment with no
//! visited-set, so a cyclic fragment — `fragment A on Q { ...B } fragment B on Q
//! { ...A }` — recurses until the native stack overflows and the process aborts.
//! That is an unauthenticated remote crash reachable from a ~60-byte query.
//!
//! `validateDocument` runs once, right after parse and before any traversal, and
//! rejects cyclic and dangling fragment spreads up front, so every later pass can
//! expand fragments knowing the graph is a DAG with no missing nodes. Its own
//! recursion is bounded by the parser's MAX_PARSE_DEPTH cap on AST height.

const std = @import("std");
const parser = @import("../lib/graphql/parser.zig");

pub const ValidationError = error{
    CyclicFragment,
    UnknownFragment,
    OutOfMemory,
};

const VisitState = enum(u2) { on_stack, done };

pub fn validateDocument(allocator: std.mem.Allocator, document: *const parser.Document) ValidationError!void {
    // name -> selections, for spread resolution.
    var frags = std.StringHashMap([]const parser.Field).init(allocator);
    defer frags.deinit();
    for (document.fragments) |*f| {
        try frags.put(f.name, f.selections);
    }

    // DFS the fragment graph: a re-entry into an on-stack node is a cycle; a
    // spread of an absent name is a dangling reference. `state` persists across
    // roots so each fragment's subtree is walked at most once.
    var state = std.StringHashMap(VisitState).init(allocator);
    defer state.deinit();

    for (document.fragments) |*f| {
        try visitFragment(&frags, &state, f.name, f.selections);
    }
    // Spreads that appear only inside operations (never inside a fragment) still
    // need their targets validated for existence; walking each operation reuses
    // the memoized `done` state so known fragments aren't re-descended.
    for (document.operations) |*op| {
        try walkSelections(&frags, &state, op.fields);
    }
}

fn visitFragment(
    frags: *std.StringHashMap([]const parser.Field),
    state: *std.StringHashMap(VisitState),
    name: []const u8,
    selections: []const parser.Field,
) ValidationError!void {
    if (state.get(name)) |s| switch (s) {
        .on_stack => return error.CyclicFragment,
        .done => return,
    };
    try state.put(name, .on_stack);
    try walkSelections(frags, state, selections);
    try state.put(name, .done);
}

fn walkSelections(
    frags: *std.StringHashMap([]const parser.Field),
    state: *std.StringHashMap(VisitState),
    selections: []const parser.Field,
) ValidationError!void {
    for (selections) |*field| {
        if (field.fragment_spread) |spread_name| {
            const target = frags.get(spread_name) orelse return error.UnknownFragment;
            try visitFragment(frags, state, spread_name, target);
        }
        // Inline fragments and ordinary fields carry nested selections; recurse.
        // Bounded by the parser's AST-height cap (MAX_PARSE_DEPTH).
        if (field.selections.len > 0) {
            try walkSelections(frags, state, field.selections);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn validateSource(allocator: std.mem.Allocator, source: []const u8) !void {
    var doc = try parser.parseQuery(allocator, source);
    defer doc.deinit(allocator);
    try validateDocument(allocator, &doc);
}

test "accepts an acyclic fragment graph" {
    try validateSource(testing.allocator,
        \\query { ...A }
        \\fragment A on Query { domains { ...B } }
        \\fragment B on Domain { name }
    );
}

test "rejects a direct fragment cycle" {
    try testing.expectError(error.CyclicFragment, validateSource(testing.allocator,
        \\query { ...A }
        \\fragment A on Query { ...A }
    ));
}

test "rejects a mutual fragment cycle" {
    try testing.expectError(error.CyclicFragment, validateSource(testing.allocator,
        \\query { ...A }
        \\fragment A on Query { field { ...B } }
        \\fragment B on Query { field { ...A } }
    ));
}

test "rejects a dangling fragment spread" {
    try testing.expectError(error.UnknownFragment, validateSource(testing.allocator,
        \\query { ...Missing }
    ));
}

test "a diamond (shared but acyclic) fragment is accepted" {
    try validateSource(testing.allocator,
        \\query { ...A ...B }
        \\fragment A on Query { x { ...C } }
        \\fragment B on Query { y { ...C } }
        \\fragment C on Query { z }
    );
}
