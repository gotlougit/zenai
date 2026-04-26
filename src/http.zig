const std = @import("std");
const retry = @import("retry.zig");

/// Error set returned by `fetchJsonWithRetry`. Each provider's `ApiError`
/// is a superset (it adds `MissingApiKey`).
pub const FetchError = error{
    ApiError,
    EmptyResponse,
} || std.http.Client.FetchError || std.json.ParseError(std.json.Scanner) || std.mem.Allocator.Error || std.Uri.ParseError;

/// Common HTTP fetch + retry + JSON parse pipeline shared by all provider
/// clients. On a non-retryable HTTP error response, calls
/// `error_handler.setErrorDetail(status, body)` so the caller can record
/// provider-specific error detail before this function returns
/// `error.ApiError`.
pub fn fetchJsonWithRetry(
    allocator: std.mem.Allocator,
    http_client: *std.http.Client,
    policy: retry.RetryPolicy,
    options: std.http.Client.FetchOptions,
    comptime T: type,
    error_handler: anytype,
) FetchError!Response(T) {
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        var response_buf: std.Io.Writer.Allocating = .init(allocator);
        var keep_buf = false;
        defer if (!keep_buf) response_buf.deinit();

        var opts = options;
        opts.response_writer = &response_buf.writer;

        const result = http_client.fetch(opts) catch |err| {
            if (retry.isRetryableFetchError(err) and attempt + 1 < policy.max_attempts) {
                retry.sleepMs(retry.backoffMs(attempt, policy));
                continue;
            }
            return err;
        };

        const body = response_buf.written();
        const status_code: u10 = @intFromEnum(result.status);
        if (status_code >= 200 and status_code < 300) {
            if (body.len == 0) return error.EmptyResponse;
            const parsed = try std.json.parseFromSlice(T, allocator, body, .{ .ignore_unknown_fields = true });
            keep_buf = true;
            return .{ .value = parsed.value, .json_buf = response_buf, .parsed = parsed };
        }

        if (retry.isRetryableStatus(status_code) and attempt + 1 < policy.max_attempts) {
            retry.sleepMs(retry.backoffMs(attempt, policy));
            continue;
        }
        error_handler.setErrorDetail(status_code, body);
        return error.ApiError;
    }
}

/// Owns the parsed response and its backing memory.
/// Call `deinit()` when done to free all resources.
pub fn Response(comptime T: type) type {
    return struct {
        value: T,
        json_buf: std.Io.Writer.Allocating,
        parsed: std.json.Parsed(T),

        pub fn deinit(self: *@This()) void {
            self.parsed.deinit();
            self.json_buf.deinit();
        }
    };
}

/// Pagination options for list operations.
pub const ListOptions = struct {
    /// Maximum number of items to return per page.
    pageSize: ?i32 = null,
    /// Token from a previous response's `nextPageToken` to fetch the next page.
    pageToken: ?[]const u8 = null,
};

/// Deep-copy a `std.json.Value`, duplicating all owned strings and containers.
pub fn dupeJsonValue(a: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    return switch (value) {
        .null, .bool, .integer, .float => value,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = try std.json.Array.initCapacity(a, arr.items.len);
            for (arr.items) |item| {
                new_arr.appendAssumeCapacity(try dupeJsonValue(a, item));
            }
            break :blk .{ .array = new_arr };
        },
        .object => |obj| blk: {
            var new_obj = std.json.ObjectMap.init(a);
            try new_obj.ensureTotalCapacity(@intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |entry| {
                new_obj.putAssumeCapacity(try a.dupe(u8, entry.key_ptr.*), try dupeJsonValue(a, entry.value_ptr.*));
            }
            break :blk .{ .object = new_obj };
        },
    };
}

/// Serialize a `std.json.Value` to a JSON string, allocated with `a`.
pub fn jsonValueToString(a: std.mem.Allocator, val: std.json.Value) std.mem.Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    std.json.Stringify.value(val, .{}, &aw.writer) catch return error.OutOfMemory;
    return aw.written();
}

pub fn appendListParams(allocator: std.mem.Allocator, base_url: []const u8, options: ListOptions) ![]u8 {
    if (options.pageSize == null and options.pageToken == null) {
        return allocator.dupe(u8, base_url);
    }
    if (options.pageSize != null and options.pageToken != null) {
        return std.fmt.allocPrint(allocator, "{s}?pageSize={d}&pageToken={s}", .{ base_url, options.pageSize.?, options.pageToken.? });
    }
    if (options.pageSize) |ps| {
        return std.fmt.allocPrint(allocator, "{s}?pageSize={d}", .{ base_url, ps });
    }
    return std.fmt.allocPrint(allocator, "{s}?pageToken={s}", .{ base_url, options.pageToken.? });
}
