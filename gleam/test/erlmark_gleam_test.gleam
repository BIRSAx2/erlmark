import erlmark_gleam as erlmark
import gleam/string
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn to_html_test() {
  assert erlmark.to_html("# Hello *world*") == "<h1>Hello <em>world</em></h1>\n"
}

pub fn gfm_table_test() {
  let html = erlmark.to_html("| a |\n|---|\n| 1 |")
  assert string.contains(html, "<table>")
  assert string.contains(html, "<td>1</td>")
}

pub fn autolink_is_opt_in_test() {
  let md = "visit www.example.com"
  assert erlmark.to_html(md) == "<p>visit www.example.com</p>\n"
  assert erlmark.to_html_with(md, erlmark.new() |> erlmark.autolink)
    == "<p>visit <a href=\"http://www.example.com\">www.example.com</a></p>\n"
}

pub fn tagfilter_test() {
  let html =
    erlmark.to_html_with(
      "<script>x</script>",
      erlmark.new() |> erlmark.tagfilter,
    )
  assert string.contains(html, "&lt;script>")
}

pub fn default_options_match_plain_conversion_test() {
  let md = "# Title\n\nSome *text* and a [link](https://example.com).\n"
  assert erlmark.to_html_with(md, erlmark.new()) == erlmark.to_html(md)
}

pub fn parallel_matches_sequential_test() {
  let md =
    string.repeat(
      "# Heading\n\nParagraph with *emphasis*.\n\n```\ncode\n```\n\n",
      2000,
    )
  let sequential = erlmark.to_html(md)
  assert erlmark.to_html_with(
      md,
      erlmark.new() |> erlmark.parallel(erlmark.Auto),
    )
    == sequential
  assert erlmark.to_html_with(
      md,
      erlmark.new() |> erlmark.parallel(erlmark.Workers(2)),
    )
    == sequential
}

pub fn spawn_threshold_does_not_change_output_test() {
  let md = string.repeat("text *x*\n\n", 100)
  assert erlmark.to_html_with(
      md,
      erlmark.new() |> erlmark.spawn_above(erlmark.Never),
    )
    == erlmark.to_html_with(
      md,
      erlmark.new() |> erlmark.spawn_above(erlmark.Bytes(0)),
    )
}

pub fn invalid_values_are_clamped_test() {
  let md = "*a*"
  let options =
    erlmark.new()
    |> erlmark.parallel(erlmark.Workers(0))
    |> erlmark.spawn_above(erlmark.Bytes(-5))
  assert erlmark.to_html_with(md, options) == erlmark.to_html(md)
}

pub fn breaks_test() {
  assert erlmark.to_html("a\nb") == "<p>a\nb</p>\n"
  assert erlmark.to_html_with("a\nb", erlmark.new() |> erlmark.breaks)
    == "<p>a<br />\nb</p>\n"
}

pub fn code_class_prefix_test() {
  let options = erlmark.new() |> erlmark.code_class_prefix("hl-")
  assert string.contains(
    erlmark.to_html_with("```erl\nx\n```", options),
    "class=\"hl-erl\"",
  )
}

pub fn safe_test() {
  assert erlmark.to_html_with(
      "<script>x</script>",
      erlmark.new() |> erlmark.safe,
    )
    == "<!-- raw HTML omitted -->\n"
  assert erlmark.to_html_with(
      "[a](javascript:alert(1))",
      erlmark.new() |> erlmark.safe,
    )
    == "<p><a href=\"\">a</a></p>\n"
  assert erlmark.to_html("<b>x</b>") == "<p><b>x</b></p>\n"
}

pub fn front_matter_test() {
  let md = "---\ntitle: x\n---\n# Hi"
  assert erlmark.to_html_with(md, erlmark.new() |> erlmark.front_matter)
    == "<h1>Hi</h1>\n"
  assert string.contains(erlmark.to_html(md), "<hr />")
}

pub fn alerts_test() {
  let html =
    erlmark.to_html_with("> [!NOTE]\n> text", erlmark.new() |> erlmark.alerts)
  assert string.contains(
    html,
    "<div class=\"markdown-alert markdown-alert-note\">",
  )
  assert string.contains(html, "<p class=\"markdown-alert-title\">Note</p>")
  assert string.contains(erlmark.to_html("> [!NOTE]\n> text"), "<blockquote>")
}

pub fn heading_ids_test() {
  assert erlmark.to_html_with(
      "# Hello World\n# Hello World",
      erlmark.new() |> erlmark.heading_ids,
    )
    == "<h1 id=\"hello-world\">Hello World</h1>\n<h1 id=\"hello-world-1\">Hello World</h1>\n"
  assert erlmark.to_html_with(
      "# A",
      erlmark.new() |> erlmark.heading_ids_with_prefix("p-"),
    )
    == "<h1 id=\"p-a\">A</h1>\n"
  assert string.contains(
    erlmark.to_html_with("# A", erlmark.new() |> erlmark.heading_anchors),
    "class=\"anchor\"",
  )
  assert erlmark.to_html("# A") == "<h1>A</h1>\n"
}
