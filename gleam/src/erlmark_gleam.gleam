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
  )
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
  )
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
  convert(
    markdown,
    options.threshold,
    options.parallel,
    options.extensions,
    options.breaks,
    options.code_class_prefix,
    options.safe,
  )
}

@external(erlang, "erlmark_gleam_ffi", "to_html")
fn convert(
  markdown: String,
  threshold: Threshold,
  parallel: Parallel,
  extensions: List(Extension),
  breaks: Bool,
  code_class_prefix: Option(String),
  safe: Bool,
) -> String
