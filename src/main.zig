const std = @import("std");
const zd = @import("zigdown");
const RawTTY = @import("RawTTY.zig");

const clap = zd.clap; // Zig-Clap dependency inherited from Zigdown

const os = std.os;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Dir = std.fs.Dir;
const File = std.fs.File;
const FileWriter = std.io.Writer(File, File.WriteError, File.write);

fn print_usage(alloc: std.mem.Allocator, comptime params: anytype) void {
    var argi = std.process.argsWithAllocator(alloc) catch return;
    const arg0: []const u8 = argi.next().?;

    const usage = "    {s} [options] [filename.md]\n\n";

    const Green = zd.utils.TextStyle{ .fg_color = .Green, .bold = true };
    const White = zd.utils.TextStyle{ .fg_color = .White };
    zd.cons.printStyled(std.debug, Green, "\nUsage:\n", .{});
    zd.cons.printStyled(std.debug, White, usage, .{arg0});
    zd.cons.printStyled(std.debug, Green, "Options:\n", .{});
    clap.help(std.io.getStdOut().writer(), clap.Help, &params, .{}) catch unreachable;
}

const Source = struct {
    dir: Dir = undefined,
    slides: ?File = null,
    root: []const u8 = undefined,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Use Zig-Clap to parse a list of arguments
    // Each arg has a short and/or long variant with optional type and help description
    const params = comptime clap.parseParamsComptime(
        \\     --help         Display help and exit
        \\ -r, --recurse      Recursively iterate the directory to find .md files
        \\ -v, --verbose      Verbose parser output
        \\ -s, --slides <str> Path to a text file containing a list of slides for the
        \\                    presentation (rather than all files in the directory)
        \\ <str>              Directory for the slide deck
        \\
    );

    // Have Clap parse the command-line arguments
    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{ .allocator = alloc });
    defer res.deinit();

    // Process args
    if (res.args.help != 0) {
        print_usage(alloc, params);
        std.process.exit(0);
    }

    var source: Source = .{};

    if (res.args.slides) |s| {
        var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const path = try std.fs.realpath(s, &path_buf);
        source.slides = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    }

    for (res.positionals) |deck| {
        var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const path = try std.fs.realpath(deck, &path_buf);
        source.root = path;

        source.dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        break;
    }

    const recurse: bool = (res.args.recurse > 0);
    const stdout = std.io.getStdOut().writer();
    try present(alloc, stdout, source, recurse);

    // Clear the screen one last time _after_ the RawTTY deinits
    _ = try stdout.write(zd.cons.clear_screen);
}

/// User-input commands while in Present mode
pub const Command = enum(u8) {
    Next,
    Previous,
};

/// Load all *.md files in the given directory; append their absolute paths to the 'slides' array
/// dir:     The directory to search
/// recurse: If true, also recursively search all child directories of 'dir'
/// slides:  The array to append all slide filenames to
fn loadSlidesFromDirectory(alloc: Allocator, dir: Dir, recurse: bool, slides: *ArrayList([]const u8)) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
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
            .directory => {
                if (recurse) {
                    const child_dir: Dir = try dir.openDir(entry.name, .{ .iterate = true });
                    try loadSlidesFromDirectory(alloc, child_dir, recurse, slides);
                }
            },
            else => {},
        }
    }
}

/// Load a list of slides to present from a single text file
fn loadSlidesFromFile(alloc: Allocator, dir: Dir, file: File, slides: *ArrayList([]const u8)) !void {
    const buf = try file.readToEndAlloc(alloc, 1_000_000);
    defer alloc.free(buf);

    var lines = std.mem.split(u8, buf, "\n");
    while (lines.next()) |name| {
        if (name.len < 1) break;

        var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const realpath = try dir.realpath(name, &path_buf);
        if (std.mem.eql(u8, ".md", std.fs.path.extension(realpath))) {
            std.debug.print("Adding slide: {s}\n", .{realpath});
            const slide: []const u8 = try alloc.dupe(u8, realpath);
            try slides.append(slide);
        }
    }
}

/// Begin the slideshow using all slides within 'dir' at the sub-path 'dirname'
/// alloc:   The allocator to use for all file reading, parsing, and rendering
/// dirname: The directory containing the slides (.md files) (relative path)
/// dir:     The directory which 'dirname' is relative to
/// recurse: If true, all *.md files in all child directories of {dir}/{dirname} will be used
pub fn present(alloc: Allocator, writer: anytype, source: Source, recurse: bool) !void {
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

    if (source.slides) |file| {
        try loadSlidesFromFile(alloc, source.dir, file, &slides);
    } else {
        try loadSlidesFromDirectory(alloc, source.dir, recurse, &slides);

        // Sort the slides
        std.sort.heap([]const u8, slides.items, {}, cmpStr);
    }

    // Begin the presentation, using stdin to go forward/backward
    var i: usize = 0;
    var update: bool = true;
    var quit: bool = false;
    while (!quit) {
        if (update) {
            const slide: []const u8 = slides.items[i];
            const file = try std.fs.openFileAbsolute(slide, .{});
            try renderFile(alloc, writer, source.root, file, i + 1, slides.items.len);
            update = false;
        }

        // Check for a keypress to advance to the next slide
        switch (raw_tty.read()) {
            'n', 'j', 'l' => { // Next Slide
                if (i < slides.items.len - 1) {
                    i += 1;
                    update = true;
                }
            },
            'p', 'h', 'k' => { // Previous Slide
                if (i > 0) {
                    i -= 1;
                    update = true;
                }
            },
            'q' => { // Quit
                quit = true;
            },
            27 => { // Escape (0x1b)
                if (raw_tty.read() == 91) { // 0x5b (??)
                    switch (raw_tty.read()) {
                        66, 67 => { // Down, Right -- Next Slide
                            if (i < slides.items.len - 1) {
                                i += 1;
                                update = true;
                            }
                        },
                        65, 68 => { // Up, Left -- Previous Slide
                            if (i > 0) {
                                i -= 1;
                                update = true;
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
}

/// Read a given Markdown file from a directory and render it to the terminal
/// Also render a slide counter in the bottom-right corner
/// The given directory is used as the 'root_dir' option for the renderer -
/// this is used to determine the path to relative includes such as images
/// and links
fn renderFile(alloc: Allocator, writer: anytype, dir: []const u8, file: File, slide_no: usize, n_slides: usize) !void {

    // Read slide file
    const md_text = try file.readToEndAlloc(alloc, 1e9);
    defer alloc.free(md_text);

    // Parse slide
    var parser: zd.Parser = zd.Parser.init(alloc, .{ .copy_input = false, .verbose = false });
    defer parser.deinit();

    try parser.parseMarkdown(md_text);

    // Clear the screen
    const wsz = try zd.gfx.getTerminalSize();
    _ = try writer.write(zd.cons.clear_screen);
    try writer.print(zd.cons.set_row_col, .{ 0, 0 });

    // Render slide
    const opts = zd.render.render_console.RenderOpts{
        .root_dir = dir,
        .indent = 2,
        .width = wsz.cols - 2,
    };
    var c_renderer = zd.consoleRenderer(writer, alloc, opts);
    defer c_renderer.deinit();

    try c_renderer.renderBlock(parser.document);

    // Display slide number
    try writer.print(zd.cons.set_row_col, .{ wsz.rows - 1, wsz.cols - 8 });
    try writer.print("{d}/{d}", .{ slide_no, n_slides });
}

/// String comparator for standard ASCII ascending sort
fn cmpStr(_: void, left: []const u8, right: []const u8) bool {
    const N = @min(left.len, right.len);
    for (0..N) |i| {
        if (left[i] > right[i])
            return false;
    }

    if (left.len <= right.len)
        return true;

    return false;
}
