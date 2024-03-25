const std = @import("std");

pub fn main() !void {
    const stdin = std.io.getStdIn().reader();
    // const stdin: std.io.Reader = std.io.getStdIn();
    std.debug.print("Awaiting keypress...\n", .{});

    var buf: [256]u8 = undefined;
    const nb = try stdin.read(buf[0..]); // Reads until a '\n'
    std.debug.print("Got {d} bytes: '{s}'\n", .{ nb, buf[0..nb] });

    // const alloc = std.heap.page_allocator;
    // const text = try stdin.readAllAlloc(alloc, 256);
    // std.debug.print("Got {s}\n", .{text});
}
