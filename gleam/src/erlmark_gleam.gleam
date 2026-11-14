//// Fast Markdown to HTML conversion, powered by
//// [erlmark](https://hex.pm/packages/erlmark): a pure Erlang CommonMark 0.31.2
//// converter with the GFM tables, strikethrough and task-list extensions.
////
//// ```gleam
//// import erlmark_gleam as erlmark
////
//// pub fn main() {
////   erlmark.to_html("# Hello *world*")
////   // -> "<h1>Hello <em>world</em></h1>\n"
////
////   "see www.example.com"
////   |> erlmark.to_html_with(erlmark.new() |> erlmark.autolink)
//// }
//// ```
////
//// Raw HTML in the input is passed through unchanged, as CommonMark requires.
//// Sanitise the output if the input is untrusted. This package only runs on the
//// Erlang target.

import gleam/list
import gleam/option.{type Option, None, Some}

/// Conversion options. Start from `new` and adjust with the builder functions.
pub opaque type Options {
  Options(
    threshold: Threshold,
    parallel: Parallel,
    extensions: List(Extension),
    breaks: Bool,
    code_class_prefix: Option(String),
    safe: Bool,
    front_matter: Bool,
    heading_ids: HeadingIds,
    heading_anchors: Bool,
  )
}

type HeadingIds {
  NoHeadingIds
  HeadingIds(prefix: String)
}

/// How many schedulers to convert a large document on. The output is identical to
/// sequential conversion. Documents under 16 KB are never split.
pub type Parallel {
  /// Convert on the calling scheduler only. The default.
  Sequential
  /// Use every online scheduler.
  Auto
  /// Use this many schedulers.
  Workers(Int)
}

/// When to hand a conversion to a short-lived helper process with a pre-sized heap,
/// which avoids most garbage collection.
pub type Threshold {
  /// Inputs larger than this many bytes use a helper process. The default is 256.
  Bytes(Int)
  /// Always convert in the calling process.
  Never
}

/// An opt-in GFM extension.
type Extension {
  Autolink
  Tagfilter
  Alerts
}

/// The default options: no extensions, sequential conversion, helper process above
/// 256 bytes.
pub fn new() -> Options {
  Options(
    threshold: Bytes(256),
    parallel: Sequential,
    extensions: [],
    breaks: False,
    code_class_prefix: None,
    safe: False,
    front_matter: False,
    heading_ids: NoHeadingIds,
    heading_anchors: False,
  )
}

/// Give every heading an `id` made from its text, as GitHub does: lowercase, letters,
/// marks, numbers, `_` and `-` kept, spaces turned into hyphens. Repeated headings get
/// `-1`, `-2` and so on. Conversion with heading ids is always sequential.
pub fn heading_ids(options: Options) -> Options {
  Options(..options, heading_ids: HeadingIds(""))
}

/// Like `heading_ids`, with a prefix added to the `id` attribute (not to links).
pub fn heading_ids_with_prefix(options: Options, prefix: String) -> Options {
  Options(..options, heading_ids: HeadingIds(prefix))
}

/// Also add an `<a class="anchor">` link to each heading. Implies `heading_ids`.
pub fn heading_anchors(options: Options) -> Options {
  Options(..options, heading_anchors: True)
}

/// Skip a leading front matter block: a first line of `---` or `+++`, closed by a line
/// with the same delimiter. The block is not rendered. An empty or unterminated block is
/// ordinary Markdown.
pub fn front_matter(options: Options) -> Options {
  Options(..options, front_matter: True)
}

/// Safe output for untrusted input. Raw HTML is replaced by `<!-- raw HTML omitted -->`,
/// and link and image destinations using the `javascript:`, `vbscript:`, `file:` or
/// `data:` schemes become empty (`data:` is kept for PNG, GIF, JPEG and WebP images).
pub fn safe(options: Options) -> Options {
  Options(..options, safe: True)
}

/// Render a line break inside a paragraph as `<br />`, as chat and comment systems
/// expect. Off by default.
pub fn breaks(options: Options) -> Options {
  Options(..options, breaks: True)
}

/// Set the prefix of the class on fenced code blocks that have an info string. The
/// default is `"language-"`.
pub fn code_class_prefix(options: Options, prefix: String) -> Options {
  Options(..options, code_class_prefix: Some(prefix))
}

/// Turn bare `www.`, `http(s)://` and `ftp://` URLs and e-mail addresses into links.
/// Conversion with extensions is always sequential.
pub fn autolink(options: Options) -> Options {
  add_extension(options, Autolink)
}

/// Escape `<script>`, `<style>` and similar tags, as the GFM tagfilter does.
/// Conversion with extensions is always sequential.
pub fn tagfilter(options: Options) -> Options {
  add_extension(options, Tagfilter)
}

/// Set the parallelism. `Workers` with fewer than one worker means `Sequential`.
pub fn parallel(options: Options, parallel: Parallel) -> Options {
  let parallel = case parallel {
    Workers(n) if n < 1 -> Sequential
    other -> other
  }
  Options(..options, parallel: parallel)
}

/// Set when conversion moves to a helper process. A negative byte count means zero.
pub fn spawn_above(options: Options, threshold: Threshold) -> Options {
  let threshold = case threshold {
    Bytes(n) if n < 0 -> Bytes(0)
    other -> other
  }
  Options(..options, threshold: threshold)
}

/// Render block quotes that start with `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`
/// or `[!CAUTION]` as GitHub-style alerts. Conversion with extensions is always sequential.
pub fn alerts(options: Options) -> Options {
  add_extension(options, Alerts)
}

fn add_extension(options: Options, extension: Extension) -> Options {
  case list.contains(options.extensions, extension) {
    True -> options
    False -> Options(..options, extensions: [extension, ..options.extensions])
  }
}

/// Convert Markdown to HTML with the default options.
///
/// ```gleam
/// to_html("*emphasis* and **strong**")
/// // -> "<p><em>emphasis</em> and <strong>strong</strong></p>\n"
/// ```
@external(erlang, "erlmark", "to_html")
pub fn to_html(markdown: String) -> String

/// Convert Markdown to HTML with the given options.
///
/// ```gleam
/// "visit www.example.com"
/// |> to_html_with(new() |> autolink)
/// // -> "<p>visit <a href=\"http://www.example.com\">www.example.com</a></p>\n"
/// ```
pub fn to_html_with(markdown: String, options: Options) -> String {
  convert(markdown, options)
}

@external(erlang, "erlmark_gleam_ffi", "convert")
fn convert(markdown: String, options: Options) -> String
