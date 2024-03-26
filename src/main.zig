const std = @import("std");
const zd = @import("zigdown");

const clap = zd.clap; // Zig-Clap dependency inherited from Zigdown

const os = std.os;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Dir = std.fs.Dir;
const File = std.fs.File;
const FileWriter = std.io.Writer(File, File.WriteError, File.write);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Use Zig-Clap to parse a list of arguments
    // Each arg has a short and/or long variant with optional type and help description
    const params = comptime clap.parseParamsComptime(
        \\     --help         Display help and exit
        \\ -d, --dir  <str>   Directory for the slide deck
        \\ -v, --verbose      Verbose parser output
    );

    // Have Clap parse the command-line arguments
    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{ .allocator = alloc });
    defer res.deinit();

    // Process args
    if (res.args.help != 0) {
        // print_usage(alloc);
        std.process.exit(0);
    }

    var dir: Dir = undefined;
    var dirname: []const u8 = undefined;
    if (res.args.dir) |deck_dir| {
        var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const realpath = try std.fs.realpath(deck_dir, &path_buf);
        dirname = realpath;
        dir = try std.fs.openDirAbsolute(realpath, .{ .iterate = true });
    } else {
        // print_usage();
        std.process.exit(0);
    }

    try present(alloc, dirname, dir);
}

pub const Command = enum(u8) {
    Next,
    Previous,
};

pub fn present(alloc: Allocator, dirname: []const u8, dir: Dir) !void {
    // const in_buf: [16]u8 = undefined;
    // const f_stdin = std.io.getStdIn();
    // const stdin = f_stdin.reader();
    const raw_tty = try RawTTY.init();
    defer raw_tty.deinit();

    // Store all of the Markdown file paths, in iterator order
    var slides = ArrayList([]const u8).init(alloc);
    defer {
        for (slides.items) |slide| {
            alloc.free(slide);
        }
        slides.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // entry.name
        switch (entry.kind) {
            .file => {
                var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                const realpath = try dir.realpath(entry.name, &path_buf);
                if (std.mem.eql(u8, ".md", std.fs.path.extension(realpath))) {
                    std.debug.print("Adding slide: {s}\n", .{realpath});
                    const slide: []const u8 = try alloc.dupe(u8, realpath);
                    try slides.append(slide);
                }
            },
            else => {},
        }
    }

    // Begin the presentation, using stdin to go forward/backward
    // TODO: uncooked / raw stdin to allow capturing, e.g., arrow keys
    var i: usize = 0;
    var update: bool = true;
    var quit: bool = false;
    while (!quit) {
        if (update) {
            const slide: []const u8 = slides.items[i];
            const file = try std.fs.openFileAbsolute(slide, .{});
            try renderFile(alloc, dirname, file);
            update = false;
        }

        // Check for a keypress to advance to the next slide
        switch (raw_tty.read()) {
            'n', 'j', 'l' => {
                if (i < slides.items.len - 1) {
                    i += 1;
                    update = true;
                    std.debug.print("got next\n", .{});
                }
            },
            'p', 'h', 'k' => {
                if (i > 0) {
                    i -= 1;
                    std.debug.print("got prev\n", .{});
                    update = true;
                }
            },
            'q' => {
                std.debug.print("got quit\n", .{});
                quit = true;
            },
            else => {},
        }
    }
}

fn renderFile(alloc: Allocator, dir: []const u8, file: File) !void {
    const stdout = std.io.getStdOut().writer();

    const md_text = try file.readToEndAlloc(alloc, 1e9);
    defer alloc.free(md_text);

    var parser: zd.Parser = zd.Parser.init(alloc, .{ .copy_input = false, .verbose = false });
    defer parser.deinit();

    try parser.parseMarkdown(md_text);

    const wsz = try zd.gfx.getTerminalSize();
    _ = try stdout.write(zd.cons.clear_screen);
    for (0..wsz.rows) |_| {
        _ = try stdout.write("\n");
    }
    try stdout.print(zd.cons.set_row_col, .{ 0, 0 });

    const opts = zd.render.render_console.RenderOpts{
        .root_dir = dir,
        .indent = 2,
        .width = wsz.cols - 2,
    };
    var c_renderer = zd.consoleRenderer(stdout, alloc, opts);
    defer c_renderer.deinit();
    try c_renderer.renderBlock(parser.document);
}

const RawTTY = struct {
    const Self = @This();
    tty: File = undefined,
    orig_termios: std.c.termios = undefined,
    writer: std.io.Writer(File, File.WriteError, File.write) = undefined,

    pub fn init() !Self {
        const linux = os.linux;

        // Store the original terminal settings for later
        // Apply the settings to enable raw TTY ('uncooked' terminal input)
        const tty = std.io.getStdIn();

        var orig_termios: std.c.termios = undefined;
        _ = std.c.tcgetattr(tty.handle, &orig_termios);
        var raw = orig_termios;

        raw.lflag = linux.tc_lflag_t{
            .ECHO = false,
            .ICANON = false,
            .ISIG = false,
            .IEXTEN = false,
        };

        raw.iflag = linux.tc_iflag_t{
            .IXON = false,
            .ICRNL = false,
            .BRKINT = false,
            .INPCK = false,
            .ISTRIP = false,
        };

        raw.cc[@intFromEnum(linux.V.TIME)] = 0;
        raw.cc[@intFromEnum(linux.V.MIN)] = 1;
        _ = std.c.tcsetattr(tty.handle, .FLUSH, &raw);

        const writer = std.io.getStdOut().writer(); // tty.writer();

        try writer.writeAll("\x1B[?25l"); // Hide the cursor
        try writer.writeAll("\x1B[s"); // Save cursor position
        try writer.writeAll("\x1B[?47h"); // Save screen
        try writer.writeAll("\x1B[?1049h"); // Enable alternative buffer

        return Self{
            .tty = tty,
            .writer = writer,
            .orig_termios = orig_termios,
        };
    }

    fn deinit(self: Self) void {
        _ = std.c.tcsetattr(self.tty.handle, .FLUSH, &self.orig_termios);

        self.writer.writeAll("\x1B[?1049l") catch {}; // Disable alternative buffer
        self.writer.writeAll("\x1B[?47l") catch {}; // Restore screen
        self.writer.writeAll("\x1B[u") catch {}; // Restore cursor position
        self.writer.writeAll("\x1B[?25h") catch {}; // Show the cursor
        // self.writer = undefined;

        self.tty.close();
        // self.tty = undefined;
    }

    pub fn read(self: Self) u8 {
        while (true) {
            var buffer: [1]u8 = undefined;
            const nb = self.tty.read(&buffer) catch return 0;
            if (nb < 1) continue;
            return buffer[0];
        }
    }

    fn moveCursor(self: Self, row: usize, col: usize) !void {
        _ = try self.writer.print("\x1B[{};{}H", .{ row + 1, col + 1 });
    }
};

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
