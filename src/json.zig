const std = @import("std");

/// Deep-copy a `std.json.Value`, duplicating all owned strings and containers.
pub fn dupeValue(a: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    return switch (value) {
        .null, .bool, .integer, .float => value,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = try std.json.Array.initCapacity(a, arr.items.len);
            for (arr.items) |item| {
                new_arr.appendAssumeCapacity(try dupeValue(a, item));
            }
            break :blk .{ .array = new_arr };
        },
        .object => |obj| blk: {
            var new_obj = std.json.ObjectMap.init(a);
            try new_obj.ensureTotalCapacity(@intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |entry| {
                new_obj.putAssumeCapacity(try a.dupe(u8, entry.key_ptr.*), try dupeValue(a, entry.value_ptr.*));
            }
            break :blk .{ .object = new_obj };
        },
    };
}

/// Serialize a `std.json.Value` to a JSON string, allocated with `a`.
pub fn valueToString(a: std.mem.Allocator, val: std.json.Value) std.mem.Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    std.json.Stringify.value(val, .{}, &aw.writer) catch return error.OutOfMemory;
    return aw.written();
}
