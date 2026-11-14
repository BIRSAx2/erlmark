# erlmark

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
{deps, [{erlmark, "0.1.0"}]}.
```

Elixir (`mix.exs`; Mix builds the rebar3 package for you):

```elixir
{:erlmark, "~> 0.1"}
```

```elixir
:erlmark.to_html("# Hello *world*")
:erlmark.to_html(markdown, parallel: :auto, extensions: [:autolink])
```

Gleam (`gleam add erlmark`; `rebar3` must be installed):

```gleam
@external(erlang, "erlmark", "to_html")
pub fn to_html(markdown: String) -> String
```

## API

```erlang
erlmark:to_html(Markdown :: iodata()) -> binary().
erlmark:to_html(Markdown :: iodata(), [Option]) -> binary().

%% Option = {spawn_above, Bytes | infinity}
%%        | {parallel, false | auto | N}
%%        | {extensions, [autolink | tagfilter]}
```

| Option | Default | Effect |
|---|---|---|
| `{spawn_above, Bytes}` | `256` | Inputs larger than `Bytes` are converted in a short-lived process with a pre-sized heap, which avoids nearly all garbage collection (15-30% faster). Errors are re-raised in the caller. `infinity` always converts in the caller. |
| `{parallel, auto \| N}` | `false` | Converts large documents on `N` schedulers (`auto` is all online). See below. |
| `{extensions, [...]}` | `[]` | `autolink`: bare `www.`, `http(s)://`, `ftp://` URLs and e-mail addresses become links. `tagfilter`: `<script>`, `<style>` and similar tags are escaped. Conversion with extensions is sequential and not tuned. |

Raw HTML in the input is passed through unchanged, as CommonMark requires.
Sanitise the output if the input is untrusted.

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
- A line after an empty list item or empty block quote can be taken as a lazy
  continuation, where CommonMark ends the container (`> -` followed by `text`).

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
