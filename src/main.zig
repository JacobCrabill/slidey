const std = @import("std");
const zd = @import("zigdown");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var parser: zd.Parser = try zd.Parser.init(alloc, .{ .copy_input = false, .verbose = true });
    defer parser.deinit();

    const test_input = "# Hello, World!\n\n## Heading 2";
    try parser.parseMarkdown(test_input);
    var c_renderer = zd.consoleRenderer(stdout, alloc, .{ .width = 70, .indent = 2 });
    try c_renderer.renderBlock(parser.document);
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
