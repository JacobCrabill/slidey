# Slidey: Elegant Slideshows in Zig

Use Markdown to create simple yet elegant slide shows

Test example:

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/slidey -d test/deck
```

## Demo

Note that rendering images requires a terminal with support for the
[Kitty Graphics Protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol). Text-capture tools
like the `asciinema` cast below are unable to capture the RGB image data of the protocol.

[![asciicast](https://asciinema.org/a/667398.png)](https://asciinema.org/a/667398)
