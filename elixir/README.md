# Erlmark

[![Hex.pm](https://img.shields.io/hexpm/v/erlmark_ex.svg)](https://hex.pm/packages/erlmark_ex)
[![Docs](https://img.shields.io/badge/docs-hexdocs-purple.svg)](https://hexdocs.pm/erlmark_ex)

Markdown to HTML for Elixir, powered by [erlmark](https://hex.pm/packages/erlmark): a
pure Erlang CommonMark 0.31.2 converter with GFM tables, strikethrough and task lists.
No NIFs, no system dependencies, and faster than the Rust-based MDEx NIF on most
documents.

## Installation

```elixir
def deps do
  [
    {:erlmark_ex, "~> 0.1"}
  ]
end
```

## Usage

```elixir
Erlmark.to_html("# Hello *world*")
#=> "<h1>Hello <em>world</em></h1>\n"
```

Options are a keyword list:

```elixir
# Opt-in GFM autolinks and the tagfilter.
Erlmark.to_html("see www.example.com", extensions: [:autolink, :tagfilter])

# Convert a large document on all schedulers. The output is identical.
Erlmark.to_html(big_markdown, parallel: :auto)
```

| Option | Default | Effect |
|---|---|---|
| `:extensions` | `[]` | `:autolink` links bare URLs and e-mail addresses; `:tagfilter` escapes `<script>`, `<style>` and similar tags. |
| `:parallel` | `false` | `:auto` or a scheduler count. Splits large documents (16 KB and up). |
| `:spawn_above` | `256` | Inputs above this many bytes are converted in a short-lived process with a pre-sized heap. `:infinity` never spawns. |

Raw HTML in the input is passed through unchanged, as CommonMark requires. Sanitise the
output if the input is untrusted.

## Development

This package lives in the `elixir/` directory of the
[erlmark repository](https://github.com/BIRSAx2/erlmark). To build against the sibling
Erlang sources instead of the Hex release:

```
ERLMARK_PATH=.. mix test
```

## License

Copyright 2026 Mouhieddine Sabir. Licensed under the Apache License, Version 2.0; see
[LICENSE](LICENSE).
