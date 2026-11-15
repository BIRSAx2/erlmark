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
    {:erlmark_ex, "~> 0.2"}
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
# Safe output for untrusted input: raw HTML and unsafe link schemes are removed.
Erlmark.to_html(user_markdown, safe: true)

# Opt-in GFM extensions.
Erlmark.to_html(markdown, extensions: [:autolink, :tagfilter, :alerts, :footnotes])

# GitHub-style heading ids, and a front matter block skipped.
Erlmark.to_html(markdown, heading_ids: true, front_matter: true)

# Convert a large document on all schedulers. The output is identical.
Erlmark.to_html(big_markdown, parallel: :auto)
```

| Option | Default | Effect |
|---|---|---|
| `:safe` | `false` | Replaces raw HTML with `<!-- raw HTML omitted -->` and empties `javascript:`, `vbscript:`, `file:` and non-image `data:` destinations. |
| `:extensions` | `[]` | `:autolink` links bare URLs and e-mail addresses; `:tagfilter` escapes `<script>`, `<style>` and similar tags; `:alerts` renders `> [!NOTE]` style alerts; `:footnotes` adds `[^label]` references and definitions. |
| `:heading_ids` | off | `true` or `{:prefix, "user-content-"}`: adds an `id` to each heading, as GitHub does. Forces sequential conversion. |
| `:heading_anchors` | `false` | Also adds an `<a class="anchor">` link to each heading. |
| `:front_matter` | `false` | Skips a leading `---` or `+++` block. |
| `:breaks` | `false` | Renders a line break inside a paragraph as `<br />`. |
| `:code_class_prefix` | `"language-"` | Prefix of the class on fenced code blocks that have an info string. |
| `:parallel` | `false` | `:auto` or a scheduler count. Splits large documents (16 KB and up). |
| `:spawn_above` | `256` | Inputs above this many bytes are converted in a short-lived process with a pre-sized heap. `:infinity` never spawns. |

Raw HTML in the input is passed through unchanged by default, as CommonMark requires. Use
`safe: true` for untrusted input.

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
