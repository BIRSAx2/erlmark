# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-11-15

### Added

- `{safe, true}`: raw HTML is replaced by `<!-- raw HTML omitted -->` and link and image
  destinations using `javascript:`, `vbscript:`, `file:` or `data:` (other than common
  image types) become empty.
- `{extensions, [alerts]}`: GFM alerts (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`,
  `[!CAUTION]`), with an optional custom title.
- `{extensions, [footnotes]}`: footnote references and definitions, numbered by first use,
  with a footnotes section and back links.
- `{heading_ids, true | {prefix, P}}` and `{heading_anchors, true}`: GitHub-style heading
  ids with numbering of repeated headings, and optional anchor links.
- `{front_matter, true}`: skip a leading `---` or `+++` front matter block.
- `{breaks, true}`: render line breaks inside paragraphs as `<br />`.
- `{code_class_prefix, P}`: change the class prefix of fenced code blocks.
- The same options in `erlmark_ex` (keyword options) and `erlmark_gleam` (builder functions).

### Fixed

- A tab after a nested container marker (`> >\t\to`, `- > \tx`) now reaches the tab stop of
  the original line, as in cmark.

## [0.1.2]

### Added

- `erlmark_ex` (Elixir) and `erlmark_gleam` (Gleam) packages in the `elixir/` and
  `gleam/` directories. They are released together with `erlmark` and always share its
  version number.

## [0.1.1]

### Fixed

- An unprefixed line after fenced code or an HTML block inside a block quote or list item
  is no longer absorbed into that block; it ends the container.
- An unprefixed line after an empty list item or block quote is no longer taken as a lazy
  continuation of it.
- A closing emphasis delimiter that can also open now matches an earlier opener first
  (`*[a*r*`, `*_*)*`).
- A `%` that does not start an escape is encoded as `%25` in link destinations.

### Changed

- API documentation expanded and published on hexdocs.

## [0.1.0]

### Added

- CommonMark 0.31.2 to HTML converter in pure Erlang (`erlmark:to_html/1,2`).
- GFM tables, strikethrough and task lists.
- Opt-in GFM extended autolinks and tagfilter via `{extensions, [autolink, tagfilter]}`.
- Opt-in parallel conversion of large documents via `{parallel, auto | N}`.
- `{spawn_above, Bytes}` to control conversion in a helper process with a pre-sized heap.

[Unreleased]: https://github.com/BIRSAx2/erlmark/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/BIRSAx2/erlmark/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/BIRSAx2/erlmark/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/BIRSAx2/erlmark/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/BIRSAx2/erlmark/releases/tag/v0.1.0
