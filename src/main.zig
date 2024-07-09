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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Use Zig-Clap to parse a list of arguments
    // Each arg has a short and/or long variant with optional type and help description
    const params = comptime clap.parseParamsComptime(
        \\     --help         Display help and exit
        \\ -d, --dir  <str>   Directory for the slide deck
        \\ -r, --recurse      Recursively iterate the directory to find .md files
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
    const recurse: bool = (res.args.recurse > 0);

    try present(alloc, dirname, dir, recurse);
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

/// Begin the slideshow using all slides within 'dir' at the sub-path 'dirname'
/// dirname: The directory containing the slides (.md files) (relative path)
/// dir:     The directory which 'dirname' is relative to
/// recurse: If true, all *.md files in all child directories of {dir}/{dirname} will be used
pub fn present(alloc: Allocator, dirname: []const u8, dir: Dir, recurse: bool) !void {
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

    try loadSlidesFromDirectory(alloc, dir, recurse, &slides);

    // Sort the slides
    std.sort.heap([]const u8, slides.items, {}, cmpStr);

    // Begin the presentation, using stdin to go forward/backward
    var i: usize = 0;
    var update: bool = true;
    var quit: bool = false;
    while (!quit) {
        if (update) {
            const slide: []const u8 = slides.items[i];
            const file = try std.fs.openFileAbsolute(slide, .{});
            try renderFile(alloc, dirname, file, i + 1, slides.items.len);
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
fn renderFile(alloc: Allocator, dir: []const u8, file: File, slide_no: usize, n_slides: usize) !void {
    const stdout = std.io.getStdOut().writer();

    // Read slide file
    const md_text = try file.readToEndAlloc(alloc, 1e9);
    defer alloc.free(md_text);

    // Parse slide
    var parser: zd.Parser = zd.Parser.init(alloc, .{ .copy_input = false, .verbose = false });
    defer parser.deinit();

    try parser.parseMarkdown(md_text);

    // Clear the screen
    const wsz = try zd.gfx.getTerminalSize();
    _ = try stdout.write(zd.cons.clear_screen);
    try stdout.print(zd.cons.set_row_col, .{ 0, 0 });

    // Render slide
    const opts = zd.render.render_console.RenderOpts{
        .root_dir = dir,
        .indent = 2,
        .width = wsz.cols - 2,
    };
    var c_renderer = zd.consoleRenderer(stdout, alloc, opts);
    defer c_renderer.deinit();

    try c_renderer.renderBlock(parser.document);

    // Display slide number
    try stdout.print(zd.cons.set_row_col, .{ wsz.rows - 1, wsz.cols - 8 });
    try stdout.print("{d}/{d}", .{ slide_no, n_slides });
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
