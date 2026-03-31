const std = @import("std");
const types = @import("types.zig");
const Client = @import("Client.zig");

const Content = types.Content;
const Part = types.Part;
const GenerationConfig = types.GenerationConfig;
const GenerateContentResponse = types.GenerateContentResponse;

const Chat = @This();

client: *Client,
model: []const u8,
config: ?GenerationConfig,
options: Client.RequestOptions,
history: std.ArrayListUnmanaged(Content),
responses: std.ArrayListUnmanaged(Client.Response(GenerateContentResponse)),
allocator: std.mem.Allocator,

pub fn init(
    client: *Client,
    model: []const u8,
    config: ?GenerationConfig,
    options: Client.RequestOptions,
) Chat {
    return .{
        .client = client,
        .model = model,
        .config = config,
        .options = options,
        .history = .empty,
        .responses = .empty,
        .allocator = client.allocator,
    };
}

pub fn deinit(self: *Chat) void {
    for (self.history.items) |entry| {
        if (std.mem.eql(u8, entry.role orelse "", "user")) {
            for (entry.parts) |part| {
                if (part.text) |txt| self.allocator.free(txt);
            }
            self.allocator.free(entry.parts);
        }
    }
    self.history.deinit(self.allocator);

    for (self.responses.items) |*resp| {
        resp.deinit();
    }
    self.responses.deinit(self.allocator);
}

pub fn sendMessage(self: *Chat, prompt: []const u8) Client.ApiError!GenerateContentResponse {
    const owned_prompt = try self.allocator.dupe(u8, prompt);
    const parts = try self.allocator.alloc(Part, 1);
    parts[0] = .{ .text = owned_prompt };
    const user_content = Content{ .role = "user", .parts = parts };
    try self.history.append(self.allocator, user_content);

    var response = self.client.generateContent(
        self.model,
        self.history.items,
        self.config,
        self.options,
    ) catch |err| {
        _ = self.history.pop();
        self.allocator.free(owned_prompt);
        self.allocator.free(parts);
        return err;
    };

    // If any append below fails, clean up response and roll back history
    errdefer {
        response.deinit();
        _ = self.history.pop();
        self.allocator.free(owned_prompt);
        self.allocator.free(parts);
    }

    try self.responses.append(self.allocator, response);

    if (response.value.candidates) |candidates| {
        if (candidates.len > 0) {
            if (candidates[0].content) |content| {
                try self.history.append(self.allocator, content);
            }
        }
    }

    return response.value;
}

pub fn getHistory(self: *const Chat) []const Content {
    return self.history.items;
}

test "Chat init and deinit" {
    var client = Client.init(std.testing.allocator, "test-key", .{});
    defer client.deinit();
    var chat = Chat.init(&client, "gemini-2.5-flash", null, .{});
    defer chat.deinit();
    try std.testing.expectEqualStrings("gemini-2.5-flash", chat.model);
    try std.testing.expectEqual(@as(usize, 0), chat.getHistory().len);
}
