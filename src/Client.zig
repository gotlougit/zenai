const std = @import("std");
const types = @import("types.zig");

const Content = types.Content;
const GenerationConfig = types.GenerationConfig;
const GenerateContentRequest = types.GenerateContentRequest;
const GenerateContentResponse = types.GenerateContentResponse;

const Client = @This();

allocator: std.mem.Allocator,
api_key: []const u8,
base_url: []const u8,
api_version: []const u8,
http_client: std.http.Client,

pub const InitOptions = struct {
    base_url: []const u8 = "https://generativelanguage.googleapis.com",
    api_version: []const u8 = "v1beta",
};

pub fn init(allocator: std.mem.Allocator, api_key: []const u8, options: InitOptions) Client {
    return .{
        .allocator = allocator,
        .api_key = api_key,
        .base_url = options.base_url,
        .api_version = options.api_version,
        .http_client = .{ .allocator = allocator },
    };
}

pub fn deinit(self: *Client) void {
    self.http_client.deinit();
}

pub const GenerateContentError = error{
    ApiError,
    MissingApiKey,
    EmptyResponse,
} || std.http.Client.FetchError || std.json.ParseError(std.json.Scanner) || std.mem.Allocator.Error || std.Uri.ParseError;

pub fn generateContent(
    self: *Client,
    model: []const u8,
    contents: []const Content,
    config: ?GenerationConfig,
) GenerateContentError!GenerateContentResponse {
    if (self.api_key.len == 0) return error.MissingApiKey;

    // Build URL
    const url = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/models/{s}:generateContent",
        .{ self.base_url, self.api_version, model },
    );
    defer self.allocator.free(url);

    // Build request body
    const req_body = GenerateContentRequest{
        .contents = contents,
        .generationConfig = config,
    };
    var payload_buf: std.Io.Writer.Allocating = .init(self.allocator);
    defer payload_buf.deinit();
    std.json.Stringify.value(req_body, .{ .emit_null_optional_fields = false }, &payload_buf.writer) catch
        return error.OutOfMemory;
    const payload = payload_buf.written();

    // Prepare response writer
    var response_buf: std.Io.Writer.Allocating = .init(self.allocator);
    defer response_buf.deinit();

    // Make HTTP request
    const result = try self.http_client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .extra_headers = &.{
            .{ .name = "x-goog-api-key", .value = self.api_key },
        },
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
        .response_writer = &response_buf.writer,
    });

    const response_body = response_buf.written();

    // Check HTTP status
    const status_code = @intFromEnum(result.status);
    if (status_code < 200 or status_code >= 300) {
        if (response_body.len > 0) {
            std.log.err("Gemini API error (HTTP {d}): {s}", .{ status_code, response_body });
        }
        return error.ApiError;
    }

    if (response_body.len == 0) return error.EmptyResponse;

    // Parse response
    const parsed = try std.json.parseFromSlice(
        GenerateContentResponse,
        self.allocator,
        response_body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    // Dupe the response so it outlives the parsed JSON
    return dupeResponse(self.allocator, parsed.value);
}

pub fn generateContentFromText(
    self: *Client,
    model: []const u8,
    prompt: []const u8,
    config: ?GenerationConfig,
) GenerateContentError!GenerateContentResponse {
    const parts = [_]types.Part{.{ .text = prompt }};
    const contents = [_]Content{.{ .role = "user", .parts = &parts }};
    return self.generateContent(model, &contents, config);
}

pub fn freeResponse(self: *Client, response: GenerateContentResponse) void {
    freeResponseAlloc(self.allocator, response);
}

fn freeResponseAlloc(allocator: std.mem.Allocator, response: GenerateContentResponse) void {
    if (response.candidates) |candidates| {
        for (candidates) |candidate| {
            if (candidate.content) |content| {
                for (content.parts) |part| {
                    if (part.text) |t| allocator.free(t);
                }
                allocator.free(content.parts);
                if (content.role) |r| allocator.free(r);
            }
            if (candidate.finishReason) |r| allocator.free(r);
        }
        allocator.free(candidates);
    }
}

fn dupeResponse(allocator: std.mem.Allocator, resp: GenerateContentResponse) std.mem.Allocator.Error!GenerateContentResponse {
    var result = resp;
    result.candidates = null;

    if (resp.candidates) |candidates| {
        const duped_candidates = try allocator.alloc(types.Candidate, candidates.len);
        errdefer allocator.free(duped_candidates);

        for (candidates, 0..) |candidate, i| {
            duped_candidates[i] = .{};

            if (candidate.finishReason) |r| {
                duped_candidates[i].finishReason = try allocator.dupe(u8, r);
            }

            if (candidate.content) |content| {
                const duped_parts = try allocator.alloc(types.Part, content.parts.len);

                for (content.parts, 0..) |part, j| {
                    duped_parts[j] = .{
                        .text = if (part.text) |t| try allocator.dupe(u8, t) else null,
                    };
                }

                duped_candidates[i].content = .{
                    .role = if (content.role) |r| try allocator.dupe(u8, r) else null,
                    .parts = duped_parts,
                };
            }
        }
        result.candidates = duped_candidates;
    }

    return result;
}

test "Client init and deinit" {
    var client = Client.init(std.testing.allocator, "test-key", .{});
    defer client.deinit();
    try std.testing.expectEqualStrings("test-key", client.api_key);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com", client.base_url);
}
