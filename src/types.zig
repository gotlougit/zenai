const std = @import("std");

// --- Request Types ---

pub const Part = struct {
    text: ?[]const u8 = null,
};

pub const Content = struct {
    role: ?[]const u8 = null,
    parts: []const Part,
};

pub const GenerationConfig = struct {
    temperature: ?f32 = null,
    maxOutputTokens: ?u32 = null,
    topP: ?f32 = null,
    topK: ?u32 = null,
};

pub const GenerateContentRequest = struct {
    contents: []const Content,
    generationConfig: ?GenerationConfig = null,
};

// --- Response Types ---

pub const GenerateContentResponse = struct {
    candidates: ?[]const Candidate = null,
    usageMetadata: ?UsageMetadata = null,

    pub fn text(self: GenerateContentResponse) ?[]const u8 {
        const candidates = self.candidates orelse return null;
        if (candidates.len == 0) return null;
        const content = candidates[0].content orelse return null;
        if (content.parts.len == 0) return null;
        return content.parts[0].text;
    }
};

pub const Candidate = struct {
    content: ?Content = null,
    finishReason: ?[]const u8 = null,
};

pub const UsageMetadata = struct {
    promptTokenCount: ?u32 = null,
    candidatesTokenCount: ?u32 = null,
    totalTokenCount: ?u32 = null,
};

pub const ApiErrorResponse = struct {
    @"error": ?ApiErrorDetail = null,
};

pub const ApiErrorDetail = struct {
    code: ?u32 = null,
    message: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

// --- Helpers ---

test "GenerateContentRequest serializes to JSON" {
    const parts = [_]Part{.{ .text = "hello" }};
    const contents = [_]Content{.{ .role = "user", .parts = &parts }};
    const req = GenerateContentRequest{
        .contents = &contents,
        .generationConfig = .{ .temperature = 0.5 },
    };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try std.json.Stringify.value(req, .{ .emit_null_optional_fields = false }, &buf.writer);
    const json = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "temperature") != null);
}

test "GenerateContentResponse.text extracts text" {
    const json =
        \\{"candidates":[{"content":{"role":"model","parts":[{"text":"I am Gemini"}]},"finishReason":"STOP"}]}
    ;
    const parsed = try std.json.parseFromSlice(
        GenerateContentResponse,
        std.testing.allocator,
        json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("I am Gemini", parsed.value.text().?);
}
