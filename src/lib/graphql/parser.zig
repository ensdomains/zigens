const std = @import("std");

// ============================================================================
// TOKEN TYPES
// ============================================================================

pub const TokenType = enum {
    // Literals
    name, // identifier
    int,
    float,
    string,

    // Punctuation
    left_brace, // {
    right_brace, // }
    left_paren, // (
    right_paren, // )
    left_bracket, // [
    right_bracket, // ]
    colon, // :
    comma, // ,
    dollar, // $ (for variables)
    exclamation, // ! (for required types)
    spread, // ... (for fragment spreads)
    at, // @ (for directives)
    equals, // = (for default values)

    // Keywords
    query,
    mutation,
    fragment,
    on,

    // Special
    eof,
    invalid,
};

pub const Token = struct {
    type: TokenType,
    value: []const u8,
    start: usize,
    end: usize,
};

// ============================================================================
// LEXER
// ============================================================================

pub const Lexer = struct {
    source: []const u8,
    pos: usize,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
        };
    }

    pub fn nextToken(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.pos >= self.source.len) {
            return Token{
                .type = .eof,
                .value = "",
                .start = self.pos,
                .end = self.pos,
            };
        }

        const start = self.pos;
        const ch = self.source[self.pos];

        // Single-character tokens
        switch (ch) {
            '{' => {
                self.pos += 1;
                return Token{ .type = .left_brace, .value = "{", .start = start, .end = self.pos };
            },
            '}' => {
                self.pos += 1;
                return Token{ .type = .right_brace, .value = "}", .start = start, .end = self.pos };
            },
            '(' => {
                self.pos += 1;
                return Token{ .type = .left_paren, .value = "(", .start = start, .end = self.pos };
            },
            ')' => {
                self.pos += 1;
                return Token{ .type = .right_paren, .value = ")", .start = start, .end = self.pos };
            },
            '[' => {
                self.pos += 1;
                return Token{ .type = .left_bracket, .value = "[", .start = start, .end = self.pos };
            },
            ']' => {
                self.pos += 1;
                return Token{ .type = .right_bracket, .value = "]", .start = start, .end = self.pos };
            },
            ':' => {
                self.pos += 1;
                return Token{ .type = .colon, .value = ":", .start = start, .end = self.pos };
            },
            ',' => {
                self.pos += 1;
                return Token{ .type = .comma, .value = ",", .start = start, .end = self.pos };
            },
            '$' => {
                self.pos += 1;
                return Token{ .type = .dollar, .value = "$", .start = start, .end = self.pos };
            },
            '!' => {
                self.pos += 1;
                return Token{ .type = .exclamation, .value = "!", .start = start, .end = self.pos };
            },
            '.' => {
                // Check for spread operator ...
                if (self.pos + 2 < self.source.len and
                    self.source[self.pos + 1] == '.' and
                    self.source[self.pos + 2] == '.')
                {
                    self.pos += 3;
                    return Token{ .type = .spread, .value = "...", .start = start, .end = self.pos };
                }
                // Single dot is invalid in GraphQL
                self.pos += 1;
                return Token{ .type = .invalid, .value = ".", .start = start, .end = self.pos };
            },
            '@' => {
                self.pos += 1;
                return Token{ .type = .at, .value = "@", .start = start, .end = self.pos };
            },
            '=' => {
                self.pos += 1;
                return Token{ .type = .equals, .value = "=", .start = start, .end = self.pos };
            },
            '"' => {
                return self.readString();
            },
            else => {},
        }

        // Numbers
        if (std.ascii.isDigit(ch) or ch == '-') {
            return self.readNumber();
        }

        // Names/Keywords
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            return self.readName();
        }

        // Unknown character
        self.pos += 1;
        return Token{ .type = .invalid, .value = self.source[start..self.pos], .start = start, .end = self.pos };
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == ',') {
                self.pos += 1;
            } else if (ch == '#') {
                // Skip comments
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn readString(self: *Lexer) Token {
        const start = self.pos;
        self.pos += 1; // Skip opening "

        while (self.pos < self.source.len and self.source[self.pos] != '"') {
            if (self.source[self.pos] == '\\') {
                self.pos += 1; // Skip escape char
            }
            self.pos += 1;
        }

        if (self.pos < self.source.len) {
            self.pos += 1; // Skip closing "
        }

        return Token{
            .type = .string,
            .value = self.source[start..self.pos],
            .start = start,
            .end = self.pos,
        };
    }

    fn readNumber(self: *Lexer) Token {
        const start = self.pos;
        var is_float = false;

        if (self.source[self.pos] == '-') {
            self.pos += 1;
        }

        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (std.ascii.isDigit(ch)) {
                self.pos += 1;
            } else if (ch == '.') {
                is_float = true;
                self.pos += 1;
            } else {
                break;
            }
        }

        return Token{
            .type = if (is_float) .float else .int,
            .value = self.source[start..self.pos],
            .start = start,
            .end = self.pos,
        };
    }

    fn readName(self: *Lexer) Token {
        const start = self.pos;

        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                self.pos += 1;
            } else {
                break;
            }
        }

        const value = self.source[start..self.pos];
        const token_type = self.getKeywordType(value);

        return Token{
            .type = token_type,
            .value = value,
            .start = start,
            .end = self.pos,
        };
    }

    fn getKeywordType(self: *Lexer, name: []const u8) TokenType {
        _ = self;
        if (std.mem.eql(u8, name, "query")) return .query;
        if (std.mem.eql(u8, name, "mutation")) return .mutation;
        if (std.mem.eql(u8, name, "fragment")) return .fragment;
        if (std.mem.eql(u8, name, "on")) return .on;
        return .name;
    }
};

// ============================================================================
// AST (Abstract Syntax Tree)
// ============================================================================

pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    null_value,
    list: []Value,
    object: []Argument,
    variable: []const u8, // Variable reference (e.g., $id)

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .list => |list| {
                for (list) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(list);
            },
            .object => |obj| {
                for (obj) |*arg| {
                    arg.deinit(allocator);
                }
                allocator.free(obj);
            },
            else => {},
        }
    }
};

pub const Argument = struct {
    name: []const u8,
    value: Value,

    pub fn deinit(self: *Argument, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
    }
};

/// GraphQL directive (e.g., @skip, @include)
pub const Directive = struct {
    name: []const u8, // Directive name (e.g., "skip", "include")
    arguments: []Argument, // Directive arguments

    pub fn deinit(self: *Directive, allocator: std.mem.Allocator) void {
        for (self.arguments) |*arg| {
            arg.deinit(allocator);
        }
        allocator.free(self.arguments);
    }
};

pub const Field = struct {
    name: []const u8,
    alias: ?[]const u8,
    arguments: []Argument,
    selections: []Field,
    fragment_spread: ?[]const u8, // If this is a fragment spread (...FragmentName), this is the fragment name
    directives: []Directive, // Field directives (e.g., @skip, @include)

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        for (self.arguments) |*arg| {
            arg.deinit(allocator);
        }
        allocator.free(self.arguments);

        for (self.selections) |*field| {
            field.deinit(allocator);
        }
        allocator.free(self.selections);

        for (self.directives) |*dir| {
            dir.deinit(allocator);
        }
        allocator.free(self.directives);
    }

    /// Check if this field is a fragment spread
    pub fn isFragmentSpread(self: *const Field) bool {
        return self.fragment_spread != null;
    }

    /// Check if this field should be skipped based on directives
    pub fn shouldSkip(self: *const Field, variables: ?*const std.StringHashMap(std.json.Value)) bool {
        for (self.directives) |*directive| {
            if (std.mem.eql(u8, directive.name, "skip")) {
                // @skip(if: condition)
                for (directive.arguments) |*arg| {
                    if (std.mem.eql(u8, arg.name, "if")) {
                        return evaluateBoolCondition(arg.value, variables);
                    }
                }
            } else if (std.mem.eql(u8, directive.name, "include")) {
                // @include(if: condition) - include if true, skip if false
                for (directive.arguments) |*arg| {
                    if (std.mem.eql(u8, arg.name, "if")) {
                        return !evaluateBoolCondition(arg.value, variables);
                    }
                }
            }
        }
        return false;
    }
};

/// Evaluate a boolean condition from a Value
fn evaluateBoolCondition(value: Value, variables: ?*const std.StringHashMap(std.json.Value)) bool {
    switch (value) {
        .boolean => |b| return b,
        .variable => |var_name| {
            if (variables) |vars| {
                if (vars.get(var_name)) |json_val| {
                    if (json_val == .bool) {
                        return json_val.bool;
                    }
                }
            }
            return false; // Default to false if variable not found
        },
        else => return false,
    }
}

pub const OperationType = enum {
    query,
    mutation,
};

pub const VariableDefinition = struct {
    name: []const u8, // Variable name (without $)
    type_name: []const u8, // Base type name (e.g., "String", "Int")
    is_list: bool, // Whether this is a list type [Type]
    list_item_required: bool, // Whether list items are required (the inner !)
    required: bool, // Whether the outer type is required (ends with !)
    default_value: ?Value, // Optional default value

    pub fn deinit(self: *VariableDefinition, allocator: std.mem.Allocator) void {
        if (self.default_value) |*val| {
            var mut_val = val.*;
            mut_val.deinit(allocator);
        }
    }

    /// Get the full type string representation (e.g., "[String!]!")
    pub fn typeString(self: *const VariableDefinition, allocator: std.mem.Allocator) ![]u8 {
        if (self.is_list) {
            const inner_bang = if (self.list_item_required) "!" else "";
            const outer_bang = if (self.required) "!" else "";
            return try std.fmt.allocPrint(allocator, "[{s}{s}]{s}", .{ self.type_name, inner_bang, outer_bang });
        } else {
            const bang = if (self.required) "!" else "";
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.type_name, bang });
        }
    }
};

pub const Operation = struct {
    type: OperationType,
    name: ?[]const u8,
    variables: []VariableDefinition, // Variable definitions
    fields: []Field,

    pub fn deinit(self: *Operation, allocator: std.mem.Allocator) void {
        for (self.variables) |*variable| {
            variable.deinit(allocator);
        }
        allocator.free(self.variables);

        for (self.fields) |*field| {
            field.deinit(allocator);
        }
        allocator.free(self.fields);
    }
};

/// Fragment definition
pub const Fragment = struct {
    name: []const u8, // Fragment name (e.g., "DomainFields")
    type_condition: []const u8, // Type the fragment applies to (e.g., "Domain")
    selections: []Field, // Fields in the fragment

    pub fn deinit(self: *Fragment, allocator: std.mem.Allocator) void {
        for (self.selections) |*field| {
            field.deinit(allocator);
        }
        allocator.free(self.selections);
    }
};

pub const Document = struct {
    operations: []Operation,
    fragments: []Fragment, // Fragment definitions

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.operations) |*op| {
            op.deinit(allocator);
        }
        allocator.free(self.operations);

        for (self.fragments) |*frag| {
            frag.deinit(allocator);
        }
        allocator.free(self.fragments);
    }
};

// ============================================================================
// PARSER
// ============================================================================

pub const Parser = struct {
    lexer: Lexer,
    current_token: Token,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
        var lexer = Lexer.init(source);
        const current_token = lexer.nextToken();

        return Parser{
            .lexer = lexer,
            .current_token = current_token,
            .allocator = allocator,
        };
    }

    pub fn parseDocument(self: *Parser) !Document {
        var operations: std.ArrayList(Operation) = .{};
        var fragments: std.ArrayList(Fragment) = .{};
        errdefer {
            for (operations.items) |*op| {
                op.deinit(self.allocator);
            }
            operations.deinit(self.allocator);
            for (fragments.items) |*frag| {
                frag.deinit(self.allocator);
            }
            fragments.deinit(self.allocator);
        }

        while (self.current_token.type != .eof) {
            if (self.current_token.type == .fragment) {
                // Parse fragment definition
                const frag = try self.parseFragment();
                try fragments.append(self.allocator, frag);
            } else {
                const op = try self.parseOperation();
                try operations.append(self.allocator, op);
            }
        }

        return Document{
            .operations = try operations.toOwnedSlice(self.allocator),
            .fragments = try fragments.toOwnedSlice(self.allocator),
        };
    }

    fn parseFragment(self: *Parser) !Fragment {
        // Expect 'fragment' keyword
        if (self.current_token.type != .fragment) {
            return error.ExpectedFragmentKeyword;
        }
        self.advance();

        // Expect fragment name
        if (self.current_token.type != .name) {
            return error.ExpectedFragmentName;
        }
        const frag_name = self.current_token.value;
        self.advance();

        // Expect 'on' keyword
        if (self.current_token.type != .on) {
            return error.ExpectedOnKeyword;
        }
        self.advance();

        // Expect type condition (type name)
        if (self.current_token.type != .name) {
            return error.ExpectedTypeName;
        }
        const type_condition = self.current_token.value;
        self.advance();

        // Parse selection set
        const selections = try self.parseSelectionSet();

        return Fragment{
            .name = frag_name,
            .type_condition = type_condition,
            .selections = selections,
        };
    }

    fn parseOperation(self: *Parser) !Operation {
        var op_type: OperationType = .query;
        var op_name: ?[]const u8 = null;

        // Check for explicit operation type
        if (self.current_token.type == .query) {
            op_type = .query;
            self.advance();

            // Optional operation name
            if (self.current_token.type == .name) {
                op_name = self.current_token.value;
                self.advance();
            }
        } else if (self.current_token.type == .mutation) {
            op_type = .mutation;
            self.advance();

            // Optional operation name
            if (self.current_token.type == .name) {
                op_name = self.current_token.value;
                self.advance();
            }
        }

        // Parse variable definitions if present
        const variables = if (self.current_token.type == .left_paren)
            try self.parseVariableDefinitions()
        else
            try self.allocator.alloc(VariableDefinition, 0);

        // Parse selection set
        const fields = try self.parseSelectionSet();

        return Operation{
            .type = op_type,
            .name = op_name,
            .variables = variables,
            .fields = fields,
        };
    }

    fn parseVariableDefinitions(self: *Parser) ![]VariableDefinition {
        // Expect (
        if (self.current_token.type != .left_paren) {
            return error.ExpectedLeftParen;
        }
        self.advance();

        var definitions: std.ArrayList(VariableDefinition) = .{};
        errdefer {
            for (definitions.items) |*def| {
                def.deinit(self.allocator);
            }
            definitions.deinit(self.allocator);
        }

        while (self.current_token.type != .right_paren and self.current_token.type != .eof) {
            // Expect $variableName
            if (self.current_token.type != .dollar) {
                return error.ExpectedDollarSign;
            }
            self.advance();

            if (self.current_token.type != .name) {
                return error.ExpectedVariableName;
            }
            const var_name = self.current_token.value;
            self.advance();

            // Expect :
            if (self.current_token.type != .colon) {
                return error.ExpectedColon;
            }
            self.advance();

            // Parse type (e.g., String, String!, [String], [String!], [String]!, [String!]!)
            var is_list = false;
            var list_item_required = false;
            var required = false;
            var type_name: []const u8 = undefined;

            // Check for list type [
            if (self.current_token.type == .left_bracket) {
                is_list = true;
                self.advance(); // Skip [

                // Expect type name inside brackets
                if (self.current_token.type != .name) {
                    return error.ExpectedTypeName;
                }
                type_name = self.current_token.value;
                self.advance();

                // Check for inner ! (list item required)
                if (self.current_token.type == .exclamation) {
                    list_item_required = true;
                    self.advance();
                }

                // Expect ]
                if (self.current_token.type != .right_bracket) {
                    return error.ExpectedRightBracket;
                }
                self.advance();
            } else if (self.current_token.type == .name) {
                // Simple type (not a list)
                type_name = self.current_token.value;
                self.advance();
            } else {
                return error.ExpectedTypeName;
            }

            // Check for outer ! (type required)
            if (self.current_token.type == .exclamation) {
                required = true;
                self.advance();
            }

            // Parse default value if present: = value
            var default_value: ?Value = null;
            if (self.current_token.type == .equals) {
                self.advance(); // Skip =
                default_value = try self.parseValue();
            }

            try definitions.append(self.allocator, .{
                .name = var_name,
                .type_name = type_name,
                .is_list = is_list,
                .list_item_required = list_item_required,
                .required = required,
                .default_value = default_value,
            });

            // Skip optional comma
            if (self.current_token.type == .comma) {
                self.advance();
            }
        }

        // Expect )
        if (self.current_token.type != .right_paren) {
            return error.ExpectedRightParen;
        }
        self.advance();

        return try definitions.toOwnedSlice(self.allocator);
    }

    fn parseSelectionSet(self: *Parser) anyerror![]Field {
        if (self.current_token.type != .left_brace) {
            return error.ExpectedLeftBrace;
        }
        self.advance(); // Skip {

        var fields: std.ArrayList(Field) = .{};
        errdefer {
            for (fields.items) |*field| {
                field.deinit(self.allocator);
            }
            fields.deinit(self.allocator);
        }

        while (self.current_token.type != .right_brace and self.current_token.type != .eof) {
            if (self.current_token.type == .spread) {
                // Parse fragment spread (...FragmentName) or inline fragment (... on Type { })
                const field = try self.parseFragmentSpread();
                try fields.append(self.allocator, field);
            } else {
                const field = try self.parseField();
                try fields.append(self.allocator, field);
            }
        }

        if (self.current_token.type != .right_brace) {
            return error.ExpectedRightBrace;
        }
        self.advance(); // Skip }

        return try fields.toOwnedSlice(self.allocator);
    }

    fn parseFragmentSpread(self: *Parser) !Field {
        // Expect ...
        if (self.current_token.type != .spread) {
            return error.ExpectedSpread;
        }
        self.advance();

        // Check for inline fragment (... on Type { ... })
        if (self.current_token.type == .on) {
            self.advance();
            // Expect type name
            if (self.current_token.type != .name) {
                return error.ExpectedTypeName;
            }
            const type_name = self.current_token.value;
            self.advance();

            // Parse directives (e.g., @skip, @include)
            const directives = try self.parseDirectives();

            // Parse selection set
            const selections = try self.parseSelectionSet();

            // Return as an inline fragment (stored in a special field format)
            return Field{
                .name = type_name, // Store the type condition as the name
                .alias = null,
                .arguments = &.{},
                .selections = selections,
                .fragment_spread = null, // Not a named fragment spread
                .directives = directives,
            };
        }

        // Expect fragment name
        if (self.current_token.type != .name) {
            return error.ExpectedFragmentName;
        }
        const frag_name = self.current_token.value;
        self.advance();

        // Parse directives (e.g., @skip, @include)
        const directives = try self.parseDirectives();

        // Return a fragment spread marker
        return Field{
            .name = frag_name,
            .alias = null,
            .arguments = &.{},
            .selections = &.{},
            .fragment_spread = frag_name,
            .directives = directives,
        };
    }

    fn parseField(self: *Parser) !Field {
        if (self.current_token.type != .name) {
            return error.ExpectedFieldName;
        }

        const name = self.current_token.value;
        var alias: ?[]const u8 = null;
        self.advance();

        // Check for alias (name: actualName)
        var field_name = name;
        if (self.current_token.type == .colon) {
            self.advance();
            if (self.current_token.type != .name) {
                return error.ExpectedFieldName;
            }
            alias = name;
            field_name = self.current_token.value;
            self.advance();
        }

        // Parse arguments
        var arguments: []Argument = &.{};
        if (self.current_token.type == .left_paren) {
            arguments = try self.parseArguments();
        }

        // Parse directives (e.g., @skip, @include)
        const directives = try self.parseDirectives();

        // Parse selections (nested fields)
        var selections: []Field = &.{};
        if (self.current_token.type == .left_brace) {
            selections = try self.parseSelectionSet();
        }

        return Field{
            .name = field_name,
            .alias = alias,
            .arguments = arguments,
            .selections = selections,
            .fragment_spread = null,
            .directives = directives,
        };
    }

    /// Parse directives like @skip(if: true) or @include(if: $showDetails)
    fn parseDirectives(self: *Parser) ![]Directive {
        var directives: std.ArrayList(Directive) = .{};
        errdefer {
            for (directives.items) |*dir| {
                dir.deinit(self.allocator);
            }
            directives.deinit(self.allocator);
        }

        // Parse directives while we see @
        while (self.current_token.type == .at) {
            self.advance(); // Skip @

            // Expect directive name
            if (self.current_token.type != .name) {
                return error.ExpectedDirectiveName;
            }
            const dir_name = self.current_token.value;
            self.advance();

            // Parse directive arguments if present
            var dir_args: []Argument = &.{};
            if (self.current_token.type == .left_paren) {
                dir_args = try self.parseArguments();
            }

            try directives.append(self.allocator, Directive{
                .name = dir_name,
                .arguments = dir_args,
            });
        }

        return try directives.toOwnedSlice(self.allocator);
    }

    fn parseArguments(self: *Parser) ![]Argument {
        if (self.current_token.type != .left_paren) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // Skip (

        var arguments: std.ArrayList(Argument) = .{};
        errdefer {
            for (arguments.items) |*arg| {
                arg.deinit(self.allocator);
            }
            arguments.deinit(self.allocator);
        }

        while (self.current_token.type != .right_paren and self.current_token.type != .eof) {
            const arg = try self.parseArgument();
            try arguments.append(self.allocator, arg);
        }

        if (self.current_token.type != .right_paren) {
            return error.ExpectedRightParen;
        }
        self.advance(); // Skip )

        return try arguments.toOwnedSlice(self.allocator);
    }

    fn parseArgument(self: *Parser) !Argument {
        if (self.current_token.type != .name) {
            return error.ExpectedArgumentName;
        }

        const arg_name = self.current_token.value;
        self.advance();

        if (self.current_token.type != .colon) {
            return error.ExpectedColon;
        }
        self.advance();

        const value = try self.parseValue();

        return Argument{
            .name = arg_name,
            .value = value,
        };
    }

    fn parseValue(self: *Parser) !Value {
        switch (self.current_token.type) {
            .dollar => {
                // Variable reference: $variableName
                self.advance();
                if (self.current_token.type != .name) {
                    return error.ExpectedVariableName;
                }
                const var_name = self.current_token.value;
                self.advance();
                return Value{ .variable = var_name };
            },
            .int => {
                const val = try std.fmt.parseInt(i64, self.current_token.value, 10);
                self.advance();
                return Value{ .int = val };
            },
            .float => {
                const val = try std.fmt.parseFloat(f64, self.current_token.value);
                self.advance();
                return Value{ .float = val };
            },
            .string => {
                // Remove quotes from string
                const str = self.current_token.value;
                const unquoted = if (str.len >= 2 and str[0] == '"' and str[str.len - 1] == '"')
                    str[1 .. str.len - 1]
                else
                    str;
                self.advance();
                return Value{ .string = unquoted };
            },
            .name => {
                const val = self.current_token.value;
                self.advance();

                // Handle boolean and null
                if (std.mem.eql(u8, val, "true")) {
                    return Value{ .boolean = true };
                } else if (std.mem.eql(u8, val, "false")) {
                    return Value{ .boolean = false };
                } else if (std.mem.eql(u8, val, "null")) {
                    return Value{ .null_value = {} };
                }

                // Otherwise treat as enum/string
                return Value{ .string = val };
            },
            .left_bracket => {
                return try self.parseListValue();
            },
            .left_brace => {
                return try self.parseObjectValue();
            },
            else => {
                return error.UnexpectedToken;
            },
        }
    }

    fn parseListValue(self: *Parser) anyerror!Value {
        if (self.current_token.type != .left_bracket) {
            return error.ExpectedLeftBracket;
        }
        self.advance(); // Skip [

        var items: std.ArrayList(Value) = .{};
        errdefer {
            for (items.items) |*item| {
                item.deinit(self.allocator);
            }
            items.deinit(self.allocator);
        }

        while (self.current_token.type != .right_bracket and self.current_token.type != .eof) {
            const val = try self.parseValue();
            try items.append(self.allocator, val);
        }

        if (self.current_token.type != .right_bracket) {
            return error.ExpectedRightBracket;
        }
        self.advance(); // Skip ]

        return Value{ .list = try items.toOwnedSlice(self.allocator) };
    }

    fn parseObjectValue(self: *Parser) anyerror!Value {
        if (self.current_token.type != .left_brace) {
            return error.ExpectedLeftBrace;
        }
        self.advance(); // Skip {

        var fields: std.ArrayList(Argument) = .{};
        errdefer {
            for (fields.items) |*field| {
                field.value.deinit(self.allocator);
            }
            fields.deinit(self.allocator);
        }

        while (self.current_token.type != .right_brace and self.current_token.type != .eof) {
            // Parse field name
            if (self.current_token.type != .name) {
                return error.ExpectedFieldName;
            }
            const field_name = self.current_token.value;
            self.advance();

            // Expect colon
            if (self.current_token.type != .colon) {
                return error.ExpectedColon;
            }
            self.advance();

            // Parse field value
            const field_value = try self.parseValue();

            try fields.append(self.allocator, Argument{
                .name = field_name,
                .value = field_value,
            });

            // Skip optional comma
            if (self.current_token.type == .comma) {
                self.advance();
            }
        }

        if (self.current_token.type != .right_brace) {
            return error.ExpectedRightBrace;
        }
        self.advance(); // Skip }

        return Value{ .object = try fields.toOwnedSlice(self.allocator) };
    }

    fn advance(self: *Parser) void {
        self.current_token = self.lexer.nextToken();
    }
};

// ============================================================================
// EXECUTOR CONTEXT
// ============================================================================

/// Context passed to field resolvers
pub const ExecutionContext = struct {
    allocator: std.mem.Allocator,
    database: *anyopaque, // Will be cast to *Database by resolvers
    loaders: ?*anyopaque, // Will be cast to *LoaderContext by resolvers (optional for backward compatibility)
};

/// Result of executing a field
pub const FieldResult = struct {
    json: []const u8,

    pub fn deinit(self: *FieldResult, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
    }
};

/// Resolver function type
pub const ResolverFn = *const fn (ctx: ExecutionContext, field: *const Field) anyerror!FieldResult;

/// Resolver map - maps field names to resolver functions
pub const ResolverMap = std.StringHashMap(ResolverFn);

/// Variable values map - maps variable names to their JSON values
pub const VariableMap = std.StringHashMap(std.json.Value);

// ============================================================================
// EXECUTOR
// ============================================================================

pub const Executor = struct {
    allocator: std.mem.Allocator,
    resolvers: ResolverMap,
    context: ExecutionContext,
    variables: ?*VariableMap, // Current variable values during execution
    fragments: []const Fragment, // Fragment definitions from the document
    variable_definitions: []const VariableDefinition, // Variable definitions from the current operation

    pub fn init(allocator: std.mem.Allocator, context: ExecutionContext) Executor {
        return .{
            .allocator = allocator,
            .resolvers = ResolverMap.init(allocator),
            .context = context,
            .variables = null,
            .fragments = &.{},
            .variable_definitions = &.{},
        };
    }

    pub fn deinit(self: *Executor) void {
        self.resolvers.deinit();
    }

    pub fn registerResolver(self: *Executor, field_name: []const u8, resolver: ResolverFn) !void {
        try self.resolvers.put(field_name, resolver);
    }

    /// Look up a fragment by name
    fn getFragment(self: *Executor, name: []const u8) ?*const Fragment {
        for (self.fragments) |*frag| {
            if (std.mem.eql(u8, frag.name, name)) {
                return frag;
            }
        }
        return null;
    }

    /// Look up a variable definition by name to check if it's nullable
    fn getVariableDefinition(self: *Executor, var_name: []const u8) ?*const VariableDefinition {
        for (self.variable_definitions) |*def| {
            if (std.mem.eql(u8, def.name, var_name)) {
                return def;
            }
        }
        return null;
    }

    /// Resolve a value, replacing variable references with actual values (recursively)
    fn resolveValue(self: *Executor, value: *const Value) !Value {
        return switch (value.*) {
            .variable => |var_name| {
                // Look up variable value
                if (self.variables) |vars| {
                    if (vars.get(var_name)) |json_val| {
                        // Convert JSON value to parser Value
                        return try self.jsonToValue(json_val);
                    }
                }
                // Variable not provided - check if it's nullable or has a default
                if (self.getVariableDefinition(var_name)) |var_def| {
                    // If variable has a default value, use it
                    if (var_def.default_value) |default_val| {
                        return default_val;
                    }
                    // If variable is not required (nullable), return null
                    if (!var_def.required) {
                        return Value.null_value;
                    }
                }
                // Variable is required but not provided - return error
                return error.UndefinedVariable;
            },
            .object => |args| {
                // Recursively resolve variables in object fields
                var resolved_args = try self.allocator.alloc(Argument, args.len);
                errdefer self.allocator.free(resolved_args);

                var resolved_count: usize = 0;
                errdefer {
                    // Clean up any values that were allocated before the error
                    for (resolved_args[0..resolved_count]) |arg| {
                        self.freeResolvedValue(arg.value);
                    }
                }

                for (args, 0..) |arg, i| {
                    resolved_args[i] = Argument{
                        .name = arg.name,
                        .value = try self.resolveValue(&arg.value),
                    };
                    resolved_count += 1;
                }
                return Value{ .object = resolved_args };
            },
            .list => |items| {
                // Recursively resolve variables in list items
                var resolved_items = try self.allocator.alloc(Value, items.len);
                errdefer self.allocator.free(resolved_items);

                var resolved_count: usize = 0;
                errdefer {
                    // Clean up any values that were allocated before the error
                    for (resolved_items[0..resolved_count]) |item| {
                        self.freeResolvedValue(item);
                    }
                }

                for (items, 0..) |item, i| {
                    resolved_items[i] = try self.resolveValue(&item);
                    resolved_count += 1;
                }
                return Value{ .list = resolved_items };
            },
            else => value.*, // Return value as-is (int, float, string, boolean, null)
        };
    }

    /// Convert JSON value to parser Value
    fn jsonToValue(self: *Executor, json_val: std.json.Value) !Value {
        return switch (json_val) {
            .integer => |i| Value{ .int = i },
            .float => |f| Value{ .float = f },
            .string => |s| Value{ .string = s },
            .bool => |b| Value{ .boolean = b },
            .null => Value.null_value,
            .array => |arr| {
                var list = try self.allocator.alloc(Value, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    list[i] = try self.jsonToValue(item);
                }
                return Value{ .list = list };
            },
            .object => |obj| {
                var args = try self.allocator.alloc(Argument, obj.count());
                var iter = obj.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| {
                    args[i] = Argument{
                        .name = entry.key_ptr.*,
                        .value = try self.jsonToValue(entry.value_ptr.*),
                    };
                    i += 1;
                }
                return Value{ .object = args };
            },
            else => {
                std.log.err("Unsupported JSON value type", .{});
                return error.UnsupportedJSONType;
            },
        };
    }

    pub fn executeDocument(self: *Executor, document: *const Document, variables_json: ?std.json.Value, operation_name: ?[]const u8) ![]u8 {
        // Store fragments for use during execution
        self.fragments = document.fragments;
        defer self.fragments = &.{};

        // Setup variables if provided
        var variables_map: VariableMap = VariableMap.init(self.allocator);
        defer variables_map.deinit();

        if (variables_json) |vars_json| {
            if (vars_json == .object) {
                var iter = vars_json.object.iterator();
                while (iter.next()) |entry| {
                    try variables_map.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }

        // Find operations to execute based on operationName
        // Per GraphQL spec: if operationName is provided, execute only that operation
        // If not provided and there's exactly one operation, execute it
        // If not provided and there are multiple operations, return error
        var operations_to_execute: []const *const Operation = &.{};
        var ops_buf: [16]*const Operation = undefined;
        var ops_count: usize = 0;

        if (operation_name) |name| {
            // Find the operation with the given name
            for (document.operations) |*operation| {
                if (operation.name) |op_name| {
                    if (std.mem.eql(u8, op_name, name)) {
                        if (ops_count < ops_buf.len) {
                            ops_buf[ops_count] = operation;
                            ops_count += 1;
                        }
                        break;
                    }
                }
            }
            if (ops_count == 0) {
                return error.OperationNotFound;
            }
            operations_to_execute = ops_buf[0..ops_count];
        } else {
            // No operationName provided
            if (document.operations.len == 1) {
                // Execute the single operation
                ops_buf[0] = &document.operations[0];
                operations_to_execute = ops_buf[0..1];
            } else if (document.operations.len > 1) {
                // Multiple operations require operationName
                return error.OperationNameRequired;
            }
            // If no operations, operations_to_execute stays empty
        }

        // Apply default values from variable definitions for operations we'll execute
        for (operations_to_execute) |operation| {
            for (operation.variables) |*var_def| {
                // If variable wasn't provided and has a default value, use the default
                if (!variables_map.contains(var_def.name)) {
                    if (var_def.default_value) |default| {
                        const json_val = valueToJson(default);
                        try variables_map.put(var_def.name, json_val);
                    }
                }
            }
        }

        // Set variables for this execution
        self.variables = &variables_map;
        defer self.variables = null;

        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        try response.appendSlice(self.allocator, "{\"data\":{");

        // Execute selected operations
        for (operations_to_execute, 0..) |operation, i| {
            if (i > 0) try response.appendSlice(self.allocator, ",");
            // Set variable definitions for this operation so resolveValue can check nullability
            self.variable_definitions = operation.variables;
            const result = try self.executeOperation(operation);
            defer self.allocator.free(result);
            try response.appendSlice(self.allocator, result);
        }

        try response.appendSlice(self.allocator, "}}");
        return try self.allocator.dupe(u8, response.items);
    }

    /// Convert parser Value to std.json.Value (for default values)
    fn valueToJson(value: Value) std.json.Value {
        return switch (value) {
            .int => |i| std.json.Value{ .integer = i },
            .float => |f| std.json.Value{ .float = f },
            .string => |s| std.json.Value{ .string = s },
            .boolean => |b| std.json.Value{ .bool = b },
            .null_value => std.json.Value.null,
            .variable => |v| std.json.Value{ .string = v }, // Variables in defaults are stored as strings
            .list => std.json.Value.null, // TODO: Handle list defaults if needed
            .object => std.json.Value.null, // TODO: Handle object defaults if needed
        };
    }

    /// Free expanded fields recursively (frees nested selections that were allocated by expandSelections)
    /// Note: expandSelections ALWAYS creates new allocations for any non-empty selections,
    /// so all non-empty selections in the returned fields are safe to free.
    fn freeExpandedFields(self: *Executor, fields: []Field) void {
        for (fields) |*field| {
            if (field.selections.len > 0) {
                // Recursively free nested selections
                // Note: the recursive call will free field.selections via its final free(fields) call
                self.freeExpandedFields(@constCast(field.selections));
            }
        }
        // Free this level's array (this also frees what was passed as field.selections to recursive calls)
        self.allocator.free(fields);
    }

    /// Expand selections, replacing fragment spreads with actual fragment fields
    /// Also filters out fields that should be skipped due to directives (@skip, @include)
    pub fn expandSelections(self: *Executor, selections: []const Field) ![]Field {
        var expanded: std.ArrayList(Field) = .{};
        errdefer expanded.deinit(self.allocator);

        for (selections) |*field| {
            // Check directives (@skip, @include) - skip this field if directive says so
            if (field.shouldSkip(self.variables)) {
                continue;
            }

            if (field.fragment_spread) |frag_name| {
                // This is a fragment spread - expand it
                if (self.getFragment(frag_name)) |frag| {
                    // Recursively expand the fragment's selections
                    const frag_fields = try self.expandSelections(frag.selections);
                    // Note: we don't free frag_fields here because we're transferring ownership
                    // of the nested selections to our result. The caller will free via freeExpandedFields.

                    for (frag_fields) |frag_field| {
                        try expanded.append(self.allocator, frag_field);
                    }
                    // Free just the array, not the contents (ownership transferred)
                    self.allocator.free(frag_fields);
                } else {
                    std.log.warn("Unknown fragment: {s}", .{frag_name});
                }
            } else if (field.selections.len > 0) {
                // This field has nested selections - expand them recursively
                var expanded_field = field.*;
                expanded_field.selections = try self.expandSelections(field.selections);
                try expanded.append(self.allocator, expanded_field);
            } else {
                // Regular field - just copy it
                try expanded.append(self.allocator, field.*);
            }
        }

        return try expanded.toOwnedSlice(self.allocator);
    }

    fn executeOperation(self: *Executor, operation: *const Operation) ![]u8 {
        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        // Expand fragments and filter by directives (@skip, @include)
        const expanded_fields = try self.expandSelections(operation.fields);
        defer self.freeExpandedFields(expanded_fields);

        // Execute all root fields (with fragments expanded and directives applied)
        var first = true;
        for (expanded_fields) |*field| {
            if (!first) try response.appendSlice(self.allocator, ",");
            first = false;

            const field_result = try self.executeField(field);
            defer self.allocator.free(field_result);
            try response.appendSlice(self.allocator, field_result);
        }

        return try self.allocator.dupe(u8, response.items);
    }

    /// Resolve all arguments in a field, replacing variable references with actual values
    pub fn resolveFieldArguments(self: *Executor, field: *const Field) ![]Argument {
        var resolved_args = try self.allocator.alloc(Argument, field.arguments.len);
        errdefer self.allocator.free(resolved_args);

        var resolved_count: usize = 0;
        errdefer {
            // Clean up any values that were allocated before the error
            for (resolved_args[0..resolved_count]) |arg| {
                self.freeResolvedValue(arg.value);
            }
        }

        for (field.arguments, 0..) |arg, i| {
            resolved_args[i] = Argument{
                .name = arg.name,
                .value = try self.resolveValue(&arg.value),
            };
            resolved_count += 1;
        }
        return resolved_args;
    }

    /// Free a resolved value that was allocated during resolution
    fn freeResolvedValue(self: *Executor, value: Value) void {
        switch (value) {
            .object => |args| {
                for (args) |arg| {
                    self.freeResolvedValue(arg.value);
                }
                self.allocator.free(args);
            },
            .list => |items| {
                for (items) |item| {
                    self.freeResolvedValue(item);
                }
                self.allocator.free(items);
            },
            else => {},
        }
    }

    fn executeField(self: *Executor, field: *const Field) ![]u8 {
        const field_name = field.alias orelse field.name;

        // Handle __typename at root level - always returns "Query"
        if (std.mem.eql(u8, field.name, "__typename")) {
            return try std.fmt.allocPrint(self.allocator, "\"{s}\":\"Query\"", .{field_name});
        }

        // Look up resolver for this field
        const resolver = self.resolvers.get(field.name) orelse {
            // No resolver found - return null
            return try std.fmt.allocPrint(self.allocator, "\"{s}\":null", .{field_name});
        };

        // Resolve arguments (replace variable references with actual values)
        const resolved_args = try self.resolveFieldArguments(field);
        defer {
            for (resolved_args) |arg| {
                self.freeResolvedValue(arg.value);
            }
            self.allocator.free(resolved_args);
        }

        // Create a field with resolved arguments
        var resolved_field = field.*;
        resolved_field.arguments = resolved_args;

        // Call resolver with resolved field
        var result = try resolver(self.context, &resolved_field);
        defer result.deinit(self.allocator);

        // Wrap result with field name (field_name already defined at start of function)
        return try std.fmt.allocPrint(self.allocator, "\"{s}\":{s}", .{ field_name, result.json });
    }
};

// ============================================================================
// HELPER FUNCTIONS FOR ARGUMENTS
// ============================================================================

pub fn getIntArg(field: *const Field, name: []const u8, default: ?i64) ?i64 {
    for (field.arguments) |*arg| {
        if (std.mem.eql(u8, arg.name, name)) {
            switch (arg.value) {
                .int => |val| return val,
                else => return default,
            }
        }
    }
    return default;
}

pub fn getStringArg(field: *const Field, name: []const u8, default: ?[]const u8) ?[]const u8 {
    for (field.arguments) |*arg| {
        if (std.mem.eql(u8, arg.name, name)) {
            switch (arg.value) {
                .string => |val| return val,
                else => return default,
            }
        }
    }
    return default;
}

pub fn getBoolArg(field: *const Field, name: []const u8, default: ?bool) ?bool {
    for (field.arguments) |*arg| {
        if (std.mem.eql(u8, arg.name, name)) {
            switch (arg.value) {
                .boolean => |val| return val,
                else => return default,
            }
        }
    }
    return default;
}

// ============================================================================
// TYPE VALIDATION - GraphQL spec-compliant argument validation
// ============================================================================

/// Error types for argument validation
pub const ValidationError = error{
    MissingRequiredArgument,
    InvalidArgumentType,
    InvalidIntValue,
    InvalidFloatValue,
    InvalidBoolValue,
    InvalidListValue,
    NullNotAllowed,
};

/// Get a required string argument, returning an error if missing or wrong type
pub fn getRequiredStringArg(field: *const Field, name: []const u8) ValidationError![]const u8 {
    for (field.arguments) |*arg| {
        if (std.mem.eql(u8, arg.name, name)) {
            return switch (arg.value) {
                .string => |val| val,
                .null_value => ValidationError.NullNotAllowed,
                else => ValidationError.InvalidArgumentType,
            };
        }
    }
    return ValidationError.MissingRequiredArgument;
}

/// Get a required int argument, returning an error if missing or wrong type
pub fn getRequiredIntArg(field: *const Field, name: []const u8) ValidationError!i64 {
    for (field.arguments) |*arg| {
        if (std.mem.eql(u8, arg.name, name)) {
            return switch (arg.value) {
                .int => |val| val,
                .null_value => ValidationError.NullNotAllowed,
                else => ValidationError.InvalidArgumentType,
            };
        }
    }
    return ValidationError.MissingRequiredArgument;
}

/// Get a required bool argument, returning an error if missing or wrong type
pub fn getRequiredBoolArg(field: *const Field, name: []const u8) ValidationError!bool {
    for (field.arguments) |*arg| {
        if (std.mem.eql(u8, arg.name, name)) {
            return switch (arg.value) {
                .boolean => |val| val,
                .null_value => ValidationError.NullNotAllowed,
                else => ValidationError.InvalidArgumentType,
            };
        }
    }
    return ValidationError.MissingRequiredArgument;
}

/// Validate that a value matches an expected GraphQL type
pub fn validateValueType(value: Value, expected_type: []const u8, required: bool) ValidationError!void {
    // Handle null values
    if (value == .null_value) {
        if (required) {
            return ValidationError.NullNotAllowed;
        }
        return; // null is valid for nullable types
    }

    // Validate based on expected type
    if (std.mem.eql(u8, expected_type, "String") or std.mem.eql(u8, expected_type, "ID")) {
        if (value != .string) {
            return ValidationError.InvalidArgumentType;
        }
    } else if (std.mem.eql(u8, expected_type, "Int")) {
        if (value != .int) {
            return ValidationError.InvalidArgumentType;
        }
    } else if (std.mem.eql(u8, expected_type, "Float")) {
        if (value != .float and value != .int) {
            // Int can be coerced to Float per GraphQL spec
            return ValidationError.InvalidArgumentType;
        }
    } else if (std.mem.eql(u8, expected_type, "Boolean")) {
        if (value != .boolean) {
            return ValidationError.InvalidArgumentType;
        }
    }
    // For custom types and enums, we don't do strict validation here
}

/// Check if an argument exists
pub fn hasArg(field: *const Field, name: []const u8) bool {
    for (field.arguments) |*arg| {
        if (std.mem.eql(u8, arg.name, name)) {
            return true;
        }
    }
    return false;
}

/// Get the type of an argument value as a string
pub fn getValueTypeName(value: Value) []const u8 {
    return switch (value) {
        .int => "Int",
        .float => "Float",
        .string => "String",
        .boolean => "Boolean",
        .null_value => "Null",
        .list => "List",
        .object => "Object",
        .variable => "Variable",
    };
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

pub fn parseQuery(allocator: std.mem.Allocator, query: []const u8) !Document {
    var parser = try Parser.init(allocator, query);
    return try parser.parseDocument();
}
