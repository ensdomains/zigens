# Production GraphQL Features - Implementation Status

## ✅ COMPLETED IN THIS SESSION

### 1. Schema Updates
- ✅ Added advanced filter fields to `DomainFilter`:
  - `name_contains_nocase: String`
  - `name_starts_with: String` 
  - `name_ends_with: String`
  - `owner_in: [String!]`

- ✅ Added advanced filter fields to `RegistrationFilter`:
  - `registrant_in: [String!]`
  - `expiryDate_gte: Int`
  - `expiryDate_lte: Int`

- ✅ Added sorting support:
  - `OrderDirection` enum (asc/desc)
  - `Domain_orderBy` enum (id, name, createdAt, expiryDate, registrationDate)
  - `Registration_orderBy` enum (id, name, registrationDate, expiryDate)
  - Updated `domains()` and `registrations()` queries with orderBy/orderDirection parameters

### 2. Bug Fixes from Earlier
- ✅ Fixed RPC client double-free bug
- ✅ Added object literal parsing to GraphQL parser
- ✅ Fixed getResolverAddress missing parameter

---

## 📝 NEXT STEPS: Implement Filter & Sort Logic

###Step 1: Extend Domain Filters
**File:** `src/api/graphql.zig` at line ~1291

Add these new filter variables after the existing ones:

```zig
// After line ~1295 (after existing filter declarations)
var filter_name_contains_nocase: ?[]const u8 = null;
var filter_name_starts_with: ?[]const u8 = null;
var filter_name_ends_with: ?[]const u8 = null;
var filter_owner_in: ?[]Address = null;
```

Add parsing logic in the filter argument loop (around line 1298):

```zig
// In the for (arg.value.object) loop, add these cases:
else if (std.mem.eql(u8, filter_arg.name, "name_contains_nocase")) {
    if (filter_arg.value == .string) {
        filter_name_contains_nocase = filter_arg.value.string;
    }
} else if (std.mem.eql(u8, filter_arg.name, "name_starts_with")) {
    if (filter_arg.value == .string) {
        filter_name_starts_with = filter_arg.value.string;
    }
} else if (std.mem.eql(u8, filter_arg.name, "name_ends_with")) {
    if (filter_arg.value == .string) {
        filter_name_ends_with = filter_arg.value.string;
    }
} else if (std.mem.eql(u8, filter_arg.name, "owner_in")) {
    if (filter_arg.value == .list) {
        var addresses = std.ArrayList(Address).init(allocator);
        for (filter_arg.value.list) |item| {
            if (item == .string) {
                if (Address.fromHex(item.string)) |addr| {
                    try addresses.append(addr);
                } else |_| {}
            }
        }
        filter_owner_in = try addresses.toOwnedSlice();
    }
}
```

Add filter application logic (after line ~1350):

```zig
// After existing filter checks, add:
if (matches and filter_name_contains_nocase != null) {
    // Case-insensitive contains
    const lower_name = try std.ascii.allocLowerString(allocator, name.name);
    defer allocator.free(lower_name);
    const lower_filter = try std.ascii.allocLowerString(allocator, filter_name_contains_nocase.?);
    defer allocator.free(lower_filter);
    if (std.mem.indexOf(u8, lower_name, lower_filter) == null) matches = false;
}

if (matches and filter_name_starts_with != null) {
    if (!std.mem.startsWith(u8, name.name, filter_name_starts_with.?)) matches = false;
}

if (matches and filter_name_ends_with != null) {
    if (!std.mem.endsWith(u8, name.name, filter_name_ends_with.?)) matches = false;
}

if (matches and filter_owner_in != null) {
    var found = false;
    for (filter_owner_in.?) |addr| {
        if (name.owner.eql(addr)) {
            found = true;
            break;
        }
    }
    if (!found) matches = false;
}
```

### Step 2: Extend Registration Filters
**File:** `src/api/graphql.zig` at line ~1447

Add filter variables:

```zig
var filter_registrant_in: ?[]Address = null;
var filter_expiry_gte: ?i64 = null;
var filter_expiry_lte: ?i64 = null;
```

Add parsing (in the filter loop):

```zig
else if (std.mem.eql(u8, filter_arg.name, "registrant_in")) {
    if (filter_arg.value == .list) {
        var addresses = std.ArrayList(Address).init(allocator);
        for (filter_arg.value.list) |item| {
            if (item == .string) {
                if (Address.fromHex(item.string)) |addr| {
                    try addresses.append(addr);
                } else |_| {}
            }
        }
        filter_registrant_in = try addresses.toOwnedSlice();
    }
} else if (std.mem.eql(u8, filter_arg.name, "expiryDate_gte")) {
    if (filter_arg.value == .int) {
        filter_expiry_gte = filter_arg.value.int;
    }
} else if (std.mem.eql(u8, filter_arg.name, "expiryDate_lte")) {
    if (filter_arg.value == .int) {
        filter_expiry_lte = filter_arg.value.int;
    }
}
```

Add filter application:

```zig
// In the filter check section:
if (matches and filter_registrant_in != null) {
    if (owner_str) |owner| {
        const owner_addr = Address.fromHex(owner) catch {
            matches = false;
            continue;
        };
        var found = false;
        for (filter_registrant_in.?) |addr| {
            if (owner_addr.eql(addr)) {
                found = true;
                break;
            }
        }
        if (!found) matches = false;
    } else {
        matches = false;
    }
}

if (matches and filter_expiry_gte != null) {
    if (event_expiry < filter_expiry_gte.?) matches = false;
}

if (matches and filter_expiry_lte != null) {
    if (event_expiry > filter_expiry_lte.?) matches = false;
}
```

### Step 3: Implement Sorting for Domains
**File:** `src/api/graphql.zig` at line ~1291

After parsing filters, add orderBy parsing:

```zig
// Parse orderBy and orderDirection
var order_by: ?[]const u8 = null;
var order_direction: []const u8 = "asc"; // default

for (field.arguments) |arg| {
    if (std.mem.eql(u8, arg.name, "orderBy")) {
        if (arg.value == .string) {
            order_by = arg.value.string;
        }
    } else if (std.mem.eql(u8, arg.name, "orderDirection")) {
        if (arg.value == .string) {
            order_direction = arg.value.string;
        }
    }
}
```

Before building JSON, sort the filtered results:

```zig
// After filtering, before JSON building, sort the results
if (order_by) |field_name| {
    const ascending = std.mem.eql(u8, order_direction, "asc");
    
    // Sort based on field
    if (std.mem.eql(u8, field_name, "name")) {
        std.sort.block(models.Name, filtered_names, {}, struct {
            fn lessThan(_: void, a: models.Name, b: models.Name) bool {
                return if (ascending)
                    std.mem.order(u8, a.name, b.name) == .lt
                else
                    std.mem.order(u8, a.name, b.name) == .gt;
            }
        }.lessThan);
    } else if (std.mem.eql(u8, field_name, "createdAt")) {
        std.sort.block(models.Name, filtered_names, {}, struct {
            fn lessThan(_: void, a: models.Name, b: models.Name) bool {
                return if (ascending) a.created_at < b.created_at else a.created_at > b.created_at;
            }
        }.lessThan);
    }
    // Add more fields as needed
}
```

### Step 4: Implement Sorting for Registrations
Similar to domains - parse orderBy/orderDirection and sort the event list before building JSON.

---

## 📋 REMAINING PRODUCTION FEATURES (For Future Sessions)

### 1. Structured Error Responses (CRITICAL)

**Create:** `src/api/graphql_errors.zig`

```zig
const std = @import("std");

pub const Location = struct {
    line: usize,
    column: usize,
};

pub const GraphQLError = struct {
    message: []const u8,
    locations: ?[]Location = null,
    path: ?[][]const u8 = null,
    extensions: ?std.json.Value = null,
    
    pub fn deinit(self: *GraphQLError, allocator: std.mem.Allocator) void {
        if (self.locations) |locs| allocator.free(locs);
        if (self.path) |p| {
            for (p) |segment| allocator.free(segment);
            allocator.free(p);
        }
    }
};

pub const GraphQLResponse = struct {
    data: ?[]const u8 = null, // JSON string
    errors: ?[]GraphQLError = null,
    
    pub fn toJson(self: *const GraphQLResponse, allocator: std.mem.Allocator) ![]u8 {
        var json: std.ArrayList(u8) = .{};
        try json.appendSlice(allocator, "{");
        
        if (self.errors) |errs| {
            try json.appendSlice(allocator, "\"errors\":[");
            for (errs, 0..) |err, i| {
                if (i > 0) try json.appendSlice(allocator, ",");
                try json.appendSlice(allocator, "{\"message\":\"");
                try json.appendSlice(allocator, err.message);
                try json.appendSlice(allocator, "\"");
                
                if (err.locations) |locs| {
                    try json.appendSlice(allocator, ",\"locations\":[");
                    for (locs, 0..) |loc, j| {
                        if (j > 0) try json.appendSlice(allocator, ",");
                        const loc_json = try std.fmt.allocPrint(allocator, 
                            "{{\"line\":{d},\"column\":{d}}}", .{loc.line, loc.column});
                        defer allocator.free(loc_json);
                        try json.appendSlice(allocator, loc_json);
                    }
                    try json.appendSlice(allocator, "]");
                }
                
                try json.appendSlice(allocator, "}");
            }
            try json.appendSlice(allocator, "]");
        }
        
        if (self.data) |d| {
            if (self.errors != null) try json.appendSlice(allocator, ",");
            try json.appendSlice(allocator, "\"data\":");
            try json.appendSlice(allocator, d);
        }
        
        try json.appendSlice(allocator, "}");
        return try json.toOwnedSlice(allocator);
    }
};
```

**Update Lexer** to track line/column:
```zig
// In Lexer struct, add:
line: usize = 1,
column: usize = 1,

// In nextChar, update position:
if (char == '\n') {
    self.line += 1;
    self.column = 1;
} else {
    self.column += 1;
}
```

**Update Token** to include location:
```zig
pub const Token = struct {
    type: TokenType,
    value: []const u8,
    line: usize,
    column: usize,
};
```

### 2. Query Validation (CRITICAL)

**Create:** `src/api/schema_registry.zig`

```zig
// Load introspection.json and build a queryable type system
// Map type names to their fields
// Map field names to their argument definitions
```

**Create:** `src/api/validation.zig`

```zig
// Implement validation rules:
// - FieldsOnCorrectType
// - ProvidedRequiredArguments  
// - ArgumentsOfCorrectType
// - ScalarLeafs
// - MaxDepthExceeded
// - ComplexityLimitExceeded
```

### 3. Variables Support (HIGH PRIORITY)

**Extend Parser** to handle:
```graphql
query GetDomain($id: String!) {
  domain(id: $id) { name }
}
```

**Add to Operation struct:**
```zig
variable_definitions: []VariableDefinition,

pub const VariableDefinition = struct {
    name: []const u8,
    type: TypeRef,
    default_value: ?Value,
};
```

**Update Executor** to accept variables map and substitute during execution.

### 4. Query Complexity Limiting (CRITICAL SECURITY)

```zig
fn calculateComplexity(field: Field, depth: usize) usize {
    var complexity: usize = 1;
    
    // Multiply by list size
    for (field.arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "first")) {
            if (arg.value == .int) {
                complexity *= @intCast(arg.value.int);
            }
        }
    }
    
    // Add nested field complexity
    for (field.selections) |sel| {
        complexity += calculateComplexity(sel, depth + 1);
    }
    
    return complexity;
}
```

---

## 🎯 TESTING CHECKLIST

When implementation is complete, test:

### Advanced Filters
- [ ] name_contains_nocase works case-insensitively
- [ ] name_starts_with filters correctly
- [ ] name_ends_with filters correctly
- [ ] owner_in accepts array and filters correctly
- [ ] registrant_in accepts array
- [ ] expiryDate_gte/lte work correctly

### Sorting
- [ ] orderBy: name works
- [ ] orderBy: createdAt works
- [ ] orderDirection: desc reverses results
- [ ] orderDirection: asc is default
- [ ] Sorting combines with filters

### Error Handling (when implemented)
- [ ] Invalid field returns structured error with location
- [ ] Missing required argument returns error
- [ ] Wrong argument type returns error
- [ ] Error includes line/column numbers
- [ ] Partial results returned when possible

### Validation (when implemented)
- [ ] Deep queries are rejected
- [ ] Complex queries are rejected
- [ ] Invalid field names caught before execution
- [ ] Required arguments validated

### Variables (when implemented)
- [ ] Can pass variables in request
- [ ] Variable types are validated
- [ ] Default values work
- [ ] Required variables checked

---

## 📊 ESTIMATED EFFORT REMAINING

| Feature | Effort | Priority |
|---------|--------|----------|
| Filters & Sorting Implementation | 2-3 hours | HIGH |
| Structured Errors | 2-3 hours | CRITICAL |
| Query Validation | 3-4 hours | CRITICAL |
| Variables Support | 2-3 hours | HIGH |
| Complexity Limiting | 1 hour | CRITICAL |
| Comprehensive Testing | 2 hours | CRITICAL |
| **TOTAL** | **12-16 hours** | |

---

## 💡 QUICK WIN: Complete Filters & Sorting First

The filter and sorting code above can be added directly to `src/api/graphql.zig` with minimal refactoring - this would provide immediate value and can be done in 2-3 hours.

The remaining features (errors, validation, variables) require more architectural changes but are critical for production deployment.
