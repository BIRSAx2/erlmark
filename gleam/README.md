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
// Safe output for untrusted input: raw HTML and unsafe link schemes are removed.
user_markdown
|> erlmark.to_html_with(erlmark.new() |> erlmark.safe)

// Opt-in GFM extensions, heading ids and front matter.
markdown
|> erlmark.to_html_with(
  erlmark.new()
  |> erlmark.autolink
  |> erlmark.tagfilter
  |> erlmark.alerts
  |> erlmark.footnotes
  |> erlmark.heading_ids
  |> erlmark.front_matter,
)

// Convert a large document on all schedulers. The output is identical.
big_markdown
|> erlmark.to_html_with(erlmark.new() |> erlmark.parallel(erlmark.Auto))
```

| Function | Effect |
|---|---|
| `safe` | Replaces raw HTML with `<!-- raw HTML omitted -->` and empties `javascript:`, `vbscript:`, `file:` and non-image `data:` destinations. |
| `autolink`, `tagfilter`, `alerts`, `footnotes` | Opt-in extensions. |
| `heading_ids`, `heading_ids_with_prefix`, `heading_anchors` | GitHub-style heading ids and anchor links. Force sequential conversion. |
| `front_matter` | Skips a leading `---` or `+++` block. |
| `breaks` | Renders a line break inside a paragraph as `<br />`. |
| `code_class_prefix` | Prefix of the class on fenced code blocks that have an info string. |
| `parallel` | `Sequential` (default), `Auto` or `Workers(n)`. Splits documents of 16 KB and up. |
| `spawn_above` | `Bytes(n)` (default 256) or `Never`: when to use a helper process with a pre-sized heap. |

Raw HTML in the input is passed through unchanged by default, as CommonMark requires. Use
`safe` for untrusted input.

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
