const std = @import("std");

/// Maximum allowed URL length
pub const MAX_URL_LENGTH: usize = 2048;

/// Validates a webhook URL for security using industry-standard std.Uri (RFC 3986)
/// Checks:
/// - Length limits
/// - Valid HTTP/HTTPS protocol only
/// - Not targeting localhost/private IPs (basic SSRF protection)
/// - No dangerous characters
pub fn validateWebhookUrl(url: []const u8) !void {
    // Check length
    if (url.len == 0) {
        return error.UrlEmpty;
    }
    if (url.len > MAX_URL_LENGTH) {
        return error.UrlTooLong;
    }

    // SECURITY: Use built-in std.Uri for RFC 3986 compliant parsing (industry standard)
    const uri = std.Uri.parse(url) catch {
        return error.InvalidUrlFormat;
    };

    // Validate scheme is HTTP or HTTPS only
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
        return error.InvalidUrlProtocol;
    }

    // Extract hostname using std.Uri's built-in host extraction
    var hostname_buf: [std.Uri.host_name_max]u8 = undefined;
    const hostname = uri.getHost(&hostname_buf) catch {
        return error.InvalidUrlFormat;
    };

    // Block localhost and common private IP ranges (basic SSRF protection)
    if (std.mem.eql(u8, hostname, "localhost") or
        std.mem.eql(u8, hostname, "127.0.0.1") or
        std.mem.startsWith(u8, hostname, "10.") or
        std.mem.startsWith(u8, hostname, "192.168.") or
        std.mem.startsWith(u8, hostname, "172.16.") or
        std.mem.startsWith(u8, hostname, "172.17.") or
        std.mem.startsWith(u8, hostname, "172.18.") or
        std.mem.startsWith(u8, hostname, "172.19.") or
        std.mem.startsWith(u8, hostname, "172.20.") or
        std.mem.startsWith(u8, hostname, "172.21.") or
        std.mem.startsWith(u8, hostname, "172.22.") or
        std.mem.startsWith(u8, hostname, "172.23.") or
        std.mem.startsWith(u8, hostname, "172.24.") or
        std.mem.startsWith(u8, hostname, "172.25.") or
        std.mem.startsWith(u8, hostname, "172.26.") or
        std.mem.startsWith(u8, hostname, "172.27.") or
        std.mem.startsWith(u8, hostname, "172.28.") or
        std.mem.startsWith(u8, hostname, "172.29.") or
        std.mem.startsWith(u8, hostname, "172.30.") or
        std.mem.startsWith(u8, hostname, "172.31.") or
        std.mem.eql(u8, hostname, "[::1]") or
        std.mem.eql(u8, hostname, "::1"))
    {
        return error.PrivateIpNotAllowed;
    }

    // Check for null bytes and control characters in URL
    for (url) |byte| {
        if (byte == 0x00) {
            return error.NullByteInUrl;
        }
        // Control characters (except tab) are not allowed in URLs
        if (byte < 0x20 and byte != 0x09) {
            return error.ControlCharacterInUrl;
        }
    }
}

test "validateWebhookUrl accepts valid HTTPS URLs" {
    try validateWebhookUrl("https://example.com/webhook");
    try validateWebhookUrl("https://api.example.com:8080/webhook");
    try validateWebhookUrl("https://example.com/webhook?token=abc123");
}

test "validateWebhookUrl accepts valid HTTP URLs" {
    try validateWebhookUrl("http://example.com/webhook");
}

test "validateWebhookUrl rejects empty URL" {
    try std.testing.expectError(error.UrlEmpty, validateWebhookUrl(""));
}

test "validateWebhookUrl rejects URL too long" {
    const long_url = "https://example.com/" ++ "x" ** 3000;
    try std.testing.expectError(error.UrlTooLong, validateWebhookUrl(long_url));
}

test "validateWebhookUrl rejects invalid protocols" {
    try std.testing.expectError(error.InvalidUrlProtocol, validateWebhookUrl("ftp://example.com"));
    try std.testing.expectError(error.InvalidUrlProtocol, validateWebhookUrl("file:///etc/passwd"));
    try std.testing.expectError(error.InvalidUrlProtocol, validateWebhookUrl("javascript:alert(1)"));
}

test "validateWebhookUrl rejects localhost" {
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://localhost/webhook"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://127.0.0.1/webhook"));
}

test "validateWebhookUrl rejects private IPs" {
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://192.168.1.1/webhook"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://10.0.0.1/webhook"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://172.16.0.1/webhook"));
}

test "validateWebhookUrl rejects null bytes" {
    const url_with_null = "http://example.com\x00/webhook";
    try std.testing.expectError(error.NullByteInUrl, validateWebhookUrl(url_with_null));
}

test "validateWebhookUrl rejects control characters" {
    const url_with_control = "http://example.com\x01/webhook";
    try std.testing.expectError(error.ControlCharacterInUrl, validateWebhookUrl(url_with_control));
}
