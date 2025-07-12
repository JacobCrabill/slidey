# Slidey: Elegant Slideshows in Zig

> [!IMPORTANT]
> This project is deprecated in favor of using [zigdown](https://github.com/JacobCrabill/zigdown)
> directly (use the 'present' command).

Use Markdown to create simple yet elegant slide shows

Test example:

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/slidey -s test/deck/slides.txt test/deck
```

## Demo

Note that rendering images requires a terminal with support for the
[Kitty Graphics Protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol). Text-capture tools
like the `asciinema` cast below are unable to capture the RGB image data of the protocol.

[![asciicast](https://asciinema.org/a/667398.png)](https://asciinema.org/a/667398)
