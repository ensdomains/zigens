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

pub const Field = struct {
    name: []const u8,
    alias: ?[]const u8,
    arguments: []Argument,
    selections: []Field,

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        for (self.arguments) |*arg| {
            arg.deinit(allocator);
        }
        allocator.free(self.arguments);

        for (self.selections) |*field| {
            field.deinit(allocator);
        }
        allocator.free(self.selections);
    }
};

pub const OperationType = enum {
    query,
    mutation,
};

pub const VariableDefinition = struct {
    name: []const u8, // Variable name (without $)
    type_name: []const u8, // Type (e.g., "String", "Int")
    required: bool, // Whether the type ends with !
    default_value: ?Value, // Optional default value

    pub fn deinit(self: *VariableDefinition, allocator: std.mem.Allocator) void {
        if (self.default_value) |*val| {
            var mut_val = val.*;
            mut_val.deinit(allocator);
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

pub const Document = struct {
    operations: []Operation,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.operations) |*op| {
            op.deinit(allocator);
        }
        allocator.free(self.operations);
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
        errdefer {
            for (operations.items) |*op| {
                op.deinit(self.allocator);
            }
            operations.deinit(self.allocator);
        }

        while (self.current_token.type != .eof) {
            const op = try self.parseOperation();
            try operations.append(self.allocator, op);
        }

        return Document{
            .operations = try operations.toOwnedSlice(self.allocator),
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

            // Parse type (e.g., String, String!, [String]!)
            if (self.current_token.type != .name) {
                return error.ExpectedTypeName;
            }
            const type_name = self.current_token.value;
            self.advance();

            // Check for ! (required)
            var required = false;
            if (self.current_token.type == .exclamation) {
                required = true;
                self.advance();
            }

            // TODO: Handle default values with = sign
            const default_value: ?Value = null;

            try definitions.append(self.allocator, .{
                .name = var_name,
                .type_name = type_name,
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
            const field = try self.parseField();
            try fields.append(self.allocator, field);
        }

        if (self.current_token.type != .right_brace) {
            return error.ExpectedRightBrace;
        }
        self.advance(); // Skip }

        return try fields.toOwnedSlice(self.allocator);
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
        };
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

    pub fn init(allocator: std.mem.Allocator, context: ExecutionContext) Executor {
        return .{
            .allocator = allocator,
            .resolvers = ResolverMap.init(allocator),
            .context = context,
            .variables = null,
        };
    }

    pub fn deinit(self: *Executor) void {
        self.resolvers.deinit();
    }

    pub fn registerResolver(self: *Executor, field_name: []const u8, resolver: ResolverFn) !void {
        try self.resolvers.put(field_name, resolver);
    }

    /// Resolve a value, replacing variable references with actual values
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
                // Variable not found - return error
                std.log.err("Variable ${s} not provided", .{var_name});
                return error.UndefinedVariable;
            },
            else => value.*, // Return value as-is
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

    pub fn executeDocument(self: *Executor, document: *const Document, variables_json: ?std.json.Value) ![]u8 {
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

        // Set variables for this execution
        self.variables = &variables_map;
        defer self.variables = null;

        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        try response.appendSlice(self.allocator, "{\"data\":{");

        // Execute all operations (typically just one)
        for (document.operations, 0..) |*operation, i| {
            if (i > 0) try response.appendSlice(self.allocator, ",");
            const result = try self.executeOperation(operation);
            defer self.allocator.free(result);
            try response.appendSlice(self.allocator, result);
        }

        try response.appendSlice(self.allocator, "}}");
        return try self.allocator.dupe(u8, response.items);
    }

    fn executeOperation(self: *Executor, operation: *const Operation) ![]u8 {
        var response: std.ArrayList(u8) = .{};
        defer response.deinit(self.allocator);

        // Execute all root fields
        var first = true;
        for (operation.fields) |*field| {
            if (!first) try response.appendSlice(self.allocator, ",");
            first = false;

            const field_result = try self.executeField(field);
            defer self.allocator.free(field_result);
            try response.appendSlice(self.allocator, field_result);
        }

        return try self.allocator.dupe(u8, response.items);
    }

    /// Resolve all arguments in a field, replacing variable references with actual values
    fn resolveFieldArguments(self: *Executor, field: *const Field) ![]Argument {
        var resolved_args = try self.allocator.alloc(Argument, field.arguments.len);
        for (field.arguments, 0..) |arg, i| {
            resolved_args[i] = Argument{
                .name = arg.name,
                .value = try self.resolveValue(&arg.value),
            };
        }
        return resolved_args;
    }

    fn executeField(self: *Executor, field: *const Field) ![]u8 {
        // Look up resolver for this field
        const resolver = self.resolvers.get(field.name) orelse {
            // No resolver found - return null
            const field_name = field.alias orelse field.name;
            return try std.fmt.allocPrint(self.allocator, "\"{s}\":null", .{field_name});
        };

        // Resolve arguments (replace variable references with actual values)
        const resolved_args = try self.resolveFieldArguments(field);
        defer self.allocator.free(resolved_args);

        // Create a field with resolved arguments
        var resolved_field = field.*;
        resolved_field.arguments = resolved_args;

        // Call resolver with resolved field
        var result = try resolver(self.context, &resolved_field);
        defer result.deinit(self.allocator);

        // Wrap result with field name
        const field_name = field.alias orelse field.name;
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
// UTILITY FUNCTIONS
// ============================================================================

pub fn parseQuery(allocator: std.mem.Allocator, query: []const u8) !Document {
    var parser = try Parser.init(allocator, query);
    return try parser.parseDocument();
}
