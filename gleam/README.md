# erlmark_gleam

[![Package Version](https://img.shields.io/hexpm/v/erlmark_gleam)](https://hex.pm/packages/erlmark_gleam)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/erlmark_gleam/)

Markdown to HTML for Gleam, powered by [erlmark](https://hex.pm/packages/erlmark): a pure
Erlang CommonMark 0.31.2 converter with GFM tables, strikethrough and task lists. No NIFs,
and faster than the Rust-based MDEx NIF on most documents. This package runs on the
Erlang target only.

## Installation

```sh
gleam add erlmark_gleam
```

`rebar3` must be installed, because Gleam builds the underlying Erlang package with it.

## Usage

```gleam
import erlmark_gleam as erlmark

pub fn main() {
  erlmark.to_html("# Hello *world*")
  // -> "<h1>Hello <em>world</em></h1>\n"
}
```

Options are built with a pipeline:

```gleam
"see www.example.com"
|> erlmark.to_html_with(
  erlmark.new()
  |> erlmark.autolink
  |> erlmark.tagfilter,
)

// Convert a large document on all schedulers. The output is identical.
big_markdown
|> erlmark.to_html_with(erlmark.new() |> erlmark.parallel(erlmark.Auto))
```

| Function | Effect |
|---|---|
| `autolink` | Links bare `www.`, `http(s)://` and `ftp://` URLs and e-mail addresses. |
| `tagfilter` | Escapes `<script>`, `<style>` and similar tags. |
| `parallel` | `Sequential` (default), `Auto` or `Workers(n)`. Splits documents of 16 KB and up. |
| `spawn_above` | `Bytes(n)` (default 256) or `Never`: when to use a helper process with a pre-sized heap. |

Raw HTML in the input is passed through unchanged, as CommonMark requires. Sanitise the
output if the input is untrusted.

Further documentation is at <https://hexdocs.pm/erlmark_gleam>.

## Development

This package lives in the `gleam/` directory of the
[erlmark repository](https://github.com/BIRSAx2/erlmark).

```sh
gleam test
gleam format --check src test
```

## License

Copyright 2026 Mouhieddine Sabir. Licensed under the Apache License, Version 2.0; see
[LICENSE](LICENSE).
