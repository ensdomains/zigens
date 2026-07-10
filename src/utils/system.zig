//! Zig 0.16 migration shim over libc for std APIs that were removed or moved
//! behind std.Io (time, sleep, Thread.Mutex/Condition, process env, fs.cwd(),
//! crypto.random). The project always links libc, so every function here maps
//! to a direct libc call with the old 0.15 std signature, letting call sites
//! migrate mechanically (`zsys.timestamp()` for `std.time.timestamp()` etc.).
//! Retire this module once the codebase adopts std.Io end-to-end.

const std = @import("std");
const c = std.c;

const path_buf_len = 4096;

fn lastErrno() c.E {
    return @enumFromInt(c._errno().*);
}

fn pathZ(buf: *[path_buf_len]u8, path: []const u8) error{NameTooLong}![*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0].ptr;
}

fn realtimeNow() c.timespec {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.REALTIME, &ts) != 0) @panic("clock_gettime(REALTIME) failed");
    return ts;
}

pub fn timestamp() i64 {
    return @intCast(realtimeNow().sec);
}

pub fn milliTimestamp() i64 {
    const ts = realtimeNow();
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

// i128 keeps the old std.time.nanoTimestamp signature: seconds * 1e9 exceeds
// i64 range headroom the old API promised callers.
pub fn nanoTimestamp() i128 {
    const ts = realtimeNow();
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn sleep(ns: u64) void {
    var req: c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: c.timespec = undefined;
    while (true) {
        const rc = c.nanosleep(&req, &rem);
        if (rc == 0) return;
        if (lastErrno() != .INTR) return;
        req = rem;
    }
}

// Zero-init is valid: glibc's PTHREAD_MUTEX_INITIALIZER / PTHREAD_COND_INITIALIZER
// are all-zero, and std.c defines them as `.{}` on the pthread types.
pub const Mutex = struct {
    impl: c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        if (c.pthread_mutex_lock(&self.impl) != .SUCCESS) @panic("pthread_mutex_lock failed");
    }

    pub fn unlock(self: *Mutex) void {
        if (c.pthread_mutex_unlock(&self.impl) != .SUCCESS) @panic("pthread_mutex_unlock failed");
    }

    pub fn tryLock(self: *Mutex) bool {
        return switch (c.pthread_mutex_trylock(&self.impl)) {
            .SUCCESS => true,
            .BUSY => false,
            else => @panic("pthread_mutex_trylock failed"),
        };
    }
};

pub const Condition = struct {
    impl: c.pthread_cond_t = .{},

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        if (c.pthread_cond_wait(&self.impl, &mutex.impl) != .SUCCESS) @panic("pthread_cond_wait failed");
    }

    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const now = realtimeNow();
        const ns_sum = @as(u64, @intCast(now.nsec)) + timeout_ns % std.time.ns_per_s;
        const abstime: c.timespec = .{
            .sec = now.sec + @as(@TypeOf(now.sec), @intCast(timeout_ns / std.time.ns_per_s + ns_sum / std.time.ns_per_s)),
            .nsec = @intCast(ns_sum % std.time.ns_per_s),
        };
        return switch (c.pthread_cond_timedwait(&self.impl, &mutex.impl, &abstime)) {
            .SUCCESS => {},
            .TIMEDOUT => error.Timeout,
            else => @panic("pthread_cond_timedwait failed"),
        };
    }

    pub fn signal(self: *Condition) void {
        if (c.pthread_cond_signal(&self.impl) != .SUCCESS) @panic("pthread_cond_signal failed");
    }

    pub fn broadcast(self: *Condition) void {
        if (c.pthread_cond_broadcast(&self.impl) != .SUCCESS) @panic("pthread_cond_broadcast failed");
    }
};

pub fn getenv(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (c.environ[i]) |entry_z| : (i += 1) {
        const entry = std.mem.sliceTo(entry_z, 0);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) return entry[eq + 1 ..];
    }
    return null;
}

pub fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const value = getenv(name) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, value);
}

pub fn hasEnv(name: []const u8) bool {
    return getenv(name) != null;
}

pub const ReadFileError = error{ FileNotFound, AccessDenied, OpenFailed, ReadFailed, FileTooBig, NameTooLong, OutOfMemory };

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ReadFileError![]u8 {
    var zbuf: [path_buf_len]u8 = undefined;
    const file = c.fopen(try pathZ(&zbuf, path), "rb") orelse return switch (lastErrno()) {
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        else => error.OpenFailed,
    };
    defer _ = c.fclose(file);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&chunk, 1, chunk.len, file);
        if (n == 0) {
            if (ferror(file) != 0) return error.ReadFailed;
            break;
        }
        if (list.items.len + n > max_bytes) return error.FileTooBig;
        try list.appendSlice(allocator, chunk[0..n]);
    }
    return list.toOwnedSlice(allocator);
}

pub const WriteFileError = error{ FileNotFound, AccessDenied, OpenFailed, WriteFailed, NameTooLong };

pub fn writeFile(path: []const u8, bytes: []const u8) WriteFileError!void {
    var zbuf: [path_buf_len]u8 = undefined;
    const file = c.fopen(try pathZ(&zbuf, path), "wb") orelse return switch (lastErrno()) {
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        else => error.OpenFailed,
    };
    const written = if (bytes.len == 0) 0 else c.fwrite(bytes.ptr, 1, bytes.len, file);
    const close_rc = c.fclose(file);
    if (written != bytes.len or close_rc != 0) return error.WriteFailed;
}

pub const MakeDirError = error{ PathAlreadyExists, FileNotFound, AccessDenied, MakeDirFailed, NameTooLong };

pub fn makeDir(path: []const u8) MakeDirError!void {
    var zbuf: [path_buf_len]u8 = undefined;
    if (c.mkdir(try pathZ(&zbuf, path), 0o755) == 0) return;
    return switch (lastErrno()) {
        .EXIST => error.PathAlreadyExists,
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        else => error.MakeDirFailed,
    };
}

pub fn makePath(path: []const u8) MakeDirError!void {
    var end: usize = 0;
    while (end < path.len) {
        end = std.mem.indexOfScalarPos(u8, path, end, '/') orelse path.len;
        if (end != 0) {
            makeDir(path[0..end]) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        end += 1;
    }
}

pub const DeleteFileError = error{ FileNotFound, AccessDenied, DeleteFailed, NameTooLong };

pub fn deleteFile(path: []const u8) DeleteFileError!void {
    var zbuf: [path_buf_len]u8 = undefined;
    if (c.unlink(try pathZ(&zbuf, path)) == 0) return;
    return switch (lastErrno()) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        else => error.DeleteFailed,
    };
}

pub fn deleteDir(path: []const u8) DeleteFileError!void {
    var zbuf: [path_buf_len]u8 = undefined;
    if (c.rmdir(try pathZ(&zbuf, path)) == 0) return;
    return switch (lastErrno()) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        else => error.DeleteFailed,
    };
}

pub fn fileExists(path: []const u8) bool {
    var zbuf: [path_buf_len]u8 = undefined;
    const z = pathZ(&zbuf, path) catch return false;
    return c.access(z, c.F_OK) == 0;
}

pub const ListFilesError = error{ FileNotFound, AccessDenied, OpenFailed, NameTooLong, OutOfMemory };

/// Regular-file names in `dir_path` (subdirectories, "." and ".." excluded),
/// unsorted. Caller frees via `freeFileList`.
pub fn listFiles(allocator: std.mem.Allocator, dir_path: []const u8) ListFilesError![][]u8 {
    var zbuf: [path_buf_len]u8 = undefined;
    const dir = c.opendir(try pathZ(&zbuf, dir_path)) orelse return switch (lastErrno()) {
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        else => error.OpenFailed,
    };
    defer _ = c.closedir(dir);

    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |name| allocator.free(name);
        list.deinit(allocator);
    }

    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (!isRegularEntry(entry.type, dir_path, name)) continue;
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try list.append(allocator, owned);
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeFileList(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

// Some filesystems report DT_UNKNOWN; probing with opendir avoids depending
// on glibc's versioned stat symbols.
fn isRegularEntry(entry_type: u8, dir_path: []const u8, name: []const u8) bool {
    if (entry_type == c.DT.REG) return true;
    if (entry_type != c.DT.UNKNOWN) return false;
    var zbuf: [path_buf_len]u8 = undefined;
    const full = std.fmt.bufPrintZ(&zbuf, "{s}/{s}", .{ dir_path, name }) catch return false;
    const sub = c.opendir(full.ptr) orelse return true;
    _ = c.closedir(sub);
    return false;
}

pub fn randomBytes(buf: []u8) void {
    const file = c.fopen("/dev/urandom", "rb") orelse @panic("open /dev/urandom failed");
    defer _ = c.fclose(file);
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = c.fread(buf.ptr + filled, 1, buf.len - filled, file);
        if (n == 0) @panic("read /dev/urandom failed");
        filled += n;
    }
}

extern "c" fn ferror(stream: *c.FILE) c_int;

const testing = std.testing;

test "timestamp family is sane and mutually consistent" {
    const ts = timestamp();
    const ms = milliTimestamp();
    const ns = nanoTimestamp();
    try testing.expect(ts > 1_700_000_000);
    try testing.expect(@abs(ms - ts * 1000) <= 2000);
    try testing.expect(@abs(@as(i128, ts) - @divTrunc(ns, std.time.ns_per_s)) <= 2);
}

test "sleep elapses at least the requested duration" {
    const before = milliTimestamp();
    sleep(5 * std.time.ns_per_ms);
    try testing.expect(milliTimestamp() - before >= 4);
}

test "Mutex lock/unlock and tryLock" {
    var m: Mutex = .{};
    m.lock();
    try testing.expect(!m.tryLock());
    m.unlock();
    try testing.expect(m.tryLock());
    m.unlock();
}

test "Condition timedWait times out" {
    var m: Mutex = .{};
    var cond: Condition = .{};
    m.lock();
    defer m.unlock();
    const before = milliTimestamp();
    try testing.expectError(error.Timeout, cond.timedWait(&m, 50 * std.time.ns_per_ms));
    try testing.expect(milliTimestamp() - before >= 40);
}

test "getenv and getEnvOwned" {
    const path = getenv("PATH");
    try testing.expect(path != null);
    try testing.expect(path.?.len > 0);

    const owned = try getEnvOwned(testing.allocator, "PATH");
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings(path.?, owned);

    try testing.expectError(
        error.EnvironmentVariableNotFound,
        getEnvOwned(testing.allocator, "ZSYS_DEFINITELY_NOT_SET_12345"),
    );
    try testing.expect(hasEnv("PATH"));
    try testing.expect(!hasEnv("ZSYS_DEFINITELY_NOT_SET_12345"));
}

test "file helpers round-trip" {
    const a = testing.allocator;
    const root = "/tmp/zsys_shim_test";
    const nested = root ++ "/a/b";
    const file_path = nested ++ "/f.txt";

    try makePath(nested);
    try makePath(nested);
    try testing.expectError(error.PathAlreadyExists, makeDir(root));

    try writeFile(file_path, "hello zsys");
    try testing.expect(fileExists(file_path));

    const content = try readFileAlloc(a, file_path, 1 << 20);
    defer a.free(content);
    try testing.expectEqualStrings("hello zsys", content);

    try testing.expectError(error.FileTooBig, readFileAlloc(a, file_path, 4));
    try testing.expectError(error.FileNotFound, readFileAlloc(a, nested ++ "/missing.txt", 1 << 20));

    try writeFile(nested ++ "/g.txt", "");
    const names = try listFiles(a, nested);
    defer freeFileList(a, names);
    try testing.expectEqual(@as(usize, 2), names.len);
    var saw_f = false;
    var saw_g = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "f.txt")) saw_f = true;
        if (std.mem.eql(u8, n, "g.txt")) saw_g = true;
    }
    try testing.expect(saw_f and saw_g);

    const root_names = try listFiles(a, root);
    defer freeFileList(a, root_names);
    try testing.expectEqual(@as(usize, 0), root_names.len);

    try deleteFile(file_path);
    try testing.expect(!fileExists(file_path));
    try testing.expectError(error.FileNotFound, deleteFile(file_path));
    try deleteFile(nested ++ "/g.txt");
    try deleteDir(nested);
    try deleteDir(root ++ "/a");
    try deleteDir(root);
}

test "randomBytes fills with entropy" {
    var one = [_]u8{0} ** 16;
    var two = [_]u8{0} ** 16;
    randomBytes(&one);
    randomBytes(&two);
    try testing.expect(!std.mem.eql(u8, &one, &two));
    try testing.expect(!std.mem.allEqual(u8, &one, 0));
}
