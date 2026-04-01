# zenai

Zig client for the [Google Gemini API](https://ai.google.dev/gemini-api/docs), ported from the official [Go Gen AI SDK](https://github.com/googleapis/go-genai).

```zig
var client = zenai.Client.init(allocator, api_key, .{});
defer client.deinit();

var response = try client.generateContentFromText("gemini-2.5-flash", "What is Zig?", .{}, .{});
defer response.deinit();

std.debug.print("{s}\n", .{response.value.text() orelse ""});
```

## Installation

```bash
zig fetch --save git+https://github.com/nicolo-ribaudo/zenai
```

Then add the dependency in your `build.zig`:

```zig
const zenai = b.dependency("zenai", .{});
exe.root_module.addImport("zenai", zenai.module("zenai"));
```

## Setup

Set your API key ([get one here](https://ai.google.dev/gemini-api/docs/api-key)):

```bash
export GOOGLE_API_KEY='your-api-key'
```

```zig
const zenai = @import("zenai");

const api_key = std.posix.getenv("GOOGLE_API_KEY") orelse return error.MissingApiKey;
var client = zenai.Client.init(allocator, api_key, .{});
defer client.deinit();
```

## Examples

### Streaming

```zig
try client.generateContentStreamFromText(
    "gemini-2.5-flash",
    "Write a poem about the moon.",
    .{},
    .{},
    {},
    &struct {
        fn cb(_: void, response: zenai.types.GenerateContentResponse) void {
            if (response.text()) |t| {
                const fd = std.posix.STDOUT_FILENO;
                _ = std.posix.write(fd, t) catch return;
            }
        }
    }.cb,
);
```

### Chat

```zig
var chat = zenai.Chat.init(&client, "gemini-2.5-flash", .{ .temperature = 0 }, .{});
defer chat.deinit();

const r1 = try chat.sendMessage("My name is Alice.");
std.debug.print("{s}\n", .{r1.text() orelse ""});

const r2 = try chat.sendMessage("What is my name?");
std.debug.print("{s}\n", .{r2.text() orelse ""});
```

### Function calling

```zig
const tools = [_]zenai.types.Tool{.{
    .functionDeclarations = &.{.{
        .name = "get_weather",
        .description = "Get the current weather for a city.",
        .parameters = .{
            .type = .OBJECT,
            .properties = &.{
                .{ .key = "city", .value = .{ .type = .STRING } },
            },
            .required = &.{"city"},
        },
    }},
}};

var response = try client.generateContentFromText(
    "gemini-2.5-flash",
    "What's the weather in Paris?",
    .{},
    .{ .tools = &tools },
);
defer response.deinit();

if (response.value.firstFunctionCall()) |fc| {
    std.debug.print("Call: {s}\n", .{fc.name orelse ""});
}
```

## Features

- Text generation and streaming (SSE)
- Multi-turn chat with history management
- Function calling and tool use
- Embeddings
- Token counting
- File uploads (resumable protocol)
- Cached content
- Model listing and info
- Safety settings and content filtering

## License

GNU Affero General Public License v3.0 — see [LICENSE](LICENSE) for details.
