# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/BIRSAx2/erlmark/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/BIRSAx2/erlmark/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/BIRSAx2/erlmark/releases/tag/v0.1.0
