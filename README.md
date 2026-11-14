# erlmark

[![CI](https://github.com/BIRSAx2/erlmark/actions/workflows/ci.yml/badge.svg)](https://github.com/BIRSAx2/erlmark/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/erlmark.svg)](https://hex.pm/packages/erlmark)
[![Docs](https://img.shields.io/badge/docs-hexdocs-purple.svg)](https://hexdocs.pm/erlmark)

A pure Erlang Markdown to HTML converter. It has no NIFs, ports or dependencies,
and needs nothing beyond Erlang/OTP.

- CommonMark 0.31.2: all 652 spec examples pass.
- GFM tables, strikethrough and task lists. Extended autolinks and the tagfilter
  are opt-in.
- Faster than the Rust-based [MDEx](https://hex.pm/packages/mdex) NIF on most
  documents, and about 100x faster than Earmark (see [Performance](#performance)).

```erlang
1> erlmark:to_html(<<"# Hello *world*">>).
<<"<h1>Hello <em>world</em></h1>\n">>
```

## Installation

Erlang (`rebar.config`):

```erlang
{deps, [{erlmark, "~> 0.1"}]}.
```

Elixir and Gleam have their own packages with native-feeling APIs, built on this one:

| Language | Package | Usage |
|---|---|---|
| Elixir | [`erlmark_ex`](https://hex.pm/packages/erlmark_ex) | `Erlmark.to_html(md, extensions: [:autolink])` |
| Gleam | [`erlmark_gleam`](https://hex.pm/packages/erlmark_gleam) | `erlmark.to_html_with(md, erlmark.new() \|> erlmark.autolink)` |

Their sources are in the [`elixir/`](https://github.com/BIRSAx2/erlmark/tree/main/elixir) and [`gleam/`](https://github.com/BIRSAx2/erlmark/tree/main/gleam) directories. You can
also call this package directly: from Elixir as `:erlmark.to_html("# Hi")`, and from Gleam
with `@external(erlang, "erlmark", "to_html")`.

## API

```erlang
erlmark:to_html(Markdown :: iodata()) -> binary().
erlmark:to_html(Markdown :: iodata(), [Option]) -> binary().

%% Option = {extensions, [autolink | tagfilter | alerts | footnotes]}
%%        | {safe, boolean()}
%%        | {breaks, boolean()}
%%        | {front_matter, boolean()}
%%        | {heading_ids, true | {prefix, iodata()}} | {heading_anchors, boolean()}
%%        | {code_class_prefix, iodata()}
%%        | {spawn_above, Bytes | infinity} | {parallel, false | auto | N}
```

| Option | Default | Effect |
|---|---|---|
| `{extensions, [...]}` | `[]` | Opt-in GFM extensions, see [Extensions](#extensions). Conversion with extensions is sequential. |
| `{safe, true}` | `false` | Safe output for untrusted input, see [Safe rendering](#safe-rendering). |
| `{breaks, true}` | `false` | A line break inside a paragraph renders as `<br />`, as chat and comment systems expect. |
| `{front_matter, true}` | `false` | Skips a leading `---` or `+++` block, closed by a line holding the same delimiter. An empty or unterminated block is ordinary Markdown. |
| `{heading_ids, true \| {prefix, P}}` | off | Adds `id` to headings, made from their text the way GitHub does (see [Heading ids](#heading-ids)). A prefix goes on the `id` attribute only. Forces sequential conversion. |
| `{heading_anchors, true}` | `false` | Also adds a `<a class="anchor">` link to each heading. Implies `heading_ids`. |
| `{code_class_prefix, P}` | `<<"language-">>` | Prefix of the class on fenced code blocks that have an info string. |
| `{spawn_above, Bytes}` | `256` | Inputs larger than `Bytes` are converted in a short-lived process with a pre-sized heap, which avoids nearly all garbage collection (15-30% faster). Errors are re-raised in the caller. `infinity` always converts in the caller. |
| `{parallel, auto \| N}` | `false` | Converts large documents on `N` schedulers (`auto` is all online). See below. |

Raw HTML in the input is passed through unchanged by default, as CommonMark requires.
Use `{safe, true}` or sanitise the output if the input is untrusted.

### Safe rendering

With `{safe, true}`:

- raw HTML blocks and inline raw HTML are replaced by `<!-- raw HTML omitted -->`;
- link and image destinations that use `javascript:`, `vbscript:`, `file:` or `data:`
  become empty. `data:` is kept for PNG, GIF, JPEG and WebP images. Browsers ignore
  leading control characters and spaces and tabs or line breaks inside a scheme, so those are
  skipped when the scheme is checked, and the check also sees destinations that came from
  character references (`&#106;avascript:`).

```erlang
1> erlmark:to_html(<<"<script>alert(1)</script>\n\n[a](javascript:alert(1))">>, [{safe, true}]).
<<"<!-- raw HTML omitted -->\n<p><a href=\"\">a</a></p>\n">>
```

Code spans and code blocks are unaffected, because their content is escaped. Safe mode is
not a general HTML sanitiser: it removes what Markdown can inject, and it does not
inspect the output of your own render hooks or post-processing.

### Extensions

Enabled with `{extensions, [...]}`. Each is off by default.

| Extension | Effect |
|---|---|
| `autolink` | Bare `www.`, `http(s)://` and `ftp://` URLs and e-mail addresses become links. |
| `tagfilter` | `<script>`, `<style>` and similar tags are escaped. |
| `alerts` | Block quotes that start with `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]` render as `<div class="markdown-alert markdown-alert-note">` with a title paragraph. Text after the marker on its line is a custom title. |
| `footnotes` | `[^label]` references and `[^label]: text` definitions. Notes are numbered in the order of first use and listed in a `<section class="footnotes">` at the end, with a back link for each use. Definitions that are never used are dropped, and a body continues on lines indented four spaces. |

```erlang
1> erlmark:to_html(<<"Text[^1].\n\n[^1]: The note.">>, [{extensions, [footnotes]}]).
```

### Heading ids

`{heading_ids, true}` gives each heading an id built from its text: lowercase, letters,
marks, numbers, `_` and `-` kept, other characters dropped, spaces turned into hyphens. A
heading that repeats gets `-1`, `-2` and so on, skipping ids that are taken. The ids are
numbered over the whole document, so conversion with heading ids is always sequential.

```erlang
1> erlmark:to_html(<<"# Hello World\n# Hello World">>, [{heading_ids, true}]).
<<"<h1 id=\"hello-world\">Hello World</h1>\n<h1 id=\"hello-world-1\">Hello World</h1>\n">>
```

### Parallel conversion

`{parallel, auto}` splits the document at top-level block boundaries and converts
the pieces concurrently. The output is byte-identical to sequential conversion,
checked by a differential fuzz test. Documents under 16 KB are never split, and
chunks are at least 2 KB.

A cut is placed at a blank line followed by an unindented letter or `#`, outside
fenced code. The block parser then reports whether a piece ended inside a fenced
code or HTML block, or defined link references (which are document-global). Such a
piece is merged with its neighbour and redone. If that happens more than once, or
any reference is defined, the whole document is converted sequentially.

Typical documents are about 2x faster, and 1.3-2.2x on fence-dense ones. This trades
CPU for latency, so it does not raise throughput on a busy node. An indented fence
whose content contains an unindented line cannot be modelled from the markers; such
documents are converted in one piece. The worst case found (hundreds of such fences)
costs about 1.2x the sequential time.

## Conformance

| Suite | Result |
|---|---|
| CommonMark 0.31.2 spec | 652 / 652 |
| GFM spec (tables, strikethrough, task lists, autolinks, tagfilter) | 22 / 22 extension examples; 661 / 672 over the full GFM spec |
| cmark regression tests | 35 / 36 |
| 500 real Markdown files, compared with MDEx | identical output |

The 11 full-GFM-spec differences come from the GFM spec being written against
CommonMark 0.29 (some emphasis rules and `language-` class prefixes changed since).
The cmark regression failure is a cmark-specific behaviour.

Known deviations:

- Block quotes and list items nest at most 64 levels. Deeper markers become
  paragraph text. Parsing nested lists is cubic in depth without a cap, and real
  documents nest about 6 levels.
- An unprefixed line after the rows of a table inside a block quote becomes one more row
  of the table. cmark-based parsers end the table and the quote there.

## Performance

Median of 3 runs, Apple Silicon, OTP 29, each implementation in a fresh process.
MDEx runs with tables, strikethrough, task lists and unsafe HTML enabled so that its
output matches erlmark's.

| Document | Earmark | MDEx (Rust NIF) | erlmark | erlmark `{parallel, auto}` |
|---|---|---|---|---|
| mixed, 4 KB | 10.8 ms | 0.319 ms | **0.064 ms** | 0.064 ms (not split) |
| mixed, 84 KB | 228 ms | 1.76 ms | **1.22 ms** | **0.70 ms** |
| image/link-heavy, 48 KB | 42.3 ms | 0.656 ms | **0.421 ms** | **0.229 ms** |
| prose, 105 KB | 153 ms | 1.12 ms | **0.798 ms** | **0.390 ms** |

Single-threaded, erlmark is 1.4-1.6x faster than MDEx on large documents and about
5x faster on small ones, where the NIF has a fixed per-call cost. With parallel mode
it is 2.5-3x faster on large documents.

Over a 52-document survey of single constructs (lists, tables, links, fences, HTML,
tabs, CRLF and so on), erlmark is faster on most and behind on a few code-heavy
shapes: fenced blocks with CRLF line endings (about 1.14x MDEx's time), a 40-line
indented code block (1.11-1.14x) and indentation mixing spaces and tabs (1.18x).
Escaping code text costs more in Erlang than in a Rust loop. Over 500 real files
(6.1 MB) erlmark takes 41 ms against MDEx's 164 ms.

What makes it fast:

- Compiled with `inline` and `{inline_size, 100}` (3-4% on mixed documents).
- Hand-written byte loops with unrolled fast paths in place of `binary:match`,
  `binary:replace` and `string:*`, whose per-call setup dominates on short strings.
- Fast paths for the common shapes: single-line paragraphs and list items,
  text-only link text, `*x*` and `**x**` resolved during the scan.
- Escaping is fused into the inline scan, and link destinations and titles are
  scanned once.
- Reference lookups are skipped when a document defines none.

## Robustness

Conversion time is linear in the input for about 75 adversarial shapes (nested and
unmatched emphasis and brackets, rule-of-3 delimiters, huge tables, lists and
quotes, long destinations and labels). Fuzz tests run arbitrary bytes and 300,000
structured inputs without a crash.

## Development

```
rebar3 eunit       # spec examples, API, worker/caller parity, fuzz,
                   # parallel == sequential differential tests
rebar3 dialyzer
```

`src/erlmark_entities.erl` is generated from the
[WHATWG entity list](https://html.spec.whatwg.org/entities.json).


## License

Copyright 2026 Mouhieddine Sabir. Licensed under the Apache License, Version 2.0;
see [LICENSE](LICENSE).
