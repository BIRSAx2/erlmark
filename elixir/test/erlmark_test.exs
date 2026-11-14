defmodule ErlmarkTest do
  use ExUnit.Case, async: true
  doctest Erlmark

  test "converts like the Erlang module" do
    md =
      "# Title\n\nSome *text* with `code`, a [link](https://example.com) and a list:\n\n- a\n- b\n"

    assert Erlmark.to_html(md) == :erlmark.to_html(md)
  end

  test "accepts iodata" do
    assert Erlmark.to_html(["# ", "Hi"]) == "<h1>Hi</h1>\n"
  end

  test "parallel conversion matches sequential" do
    md = String.duplicate("# Heading\n\nParagraph with *emphasis*.\n\n```\ncode\n```\n\n", 2_000)
    assert Erlmark.to_html(md, parallel: :auto) == Erlmark.to_html(md)
    assert Erlmark.to_html(md, parallel: 2) == Erlmark.to_html(md)
  end

  test "spawn_above never changes the result" do
    md = String.duplicate("text *x*\n\n", 100)
    assert Erlmark.to_html(md, spawn_above: :infinity) == Erlmark.to_html(md, spawn_above: 0)
  end

  test "tagfilter escapes script tags" do
    assert Erlmark.to_html("<script>x</script>", extensions: [:tagfilter]) =~ "&lt;script>"
  end

  test "breaks and code_class_prefix" do
    assert Erlmark.to_html("a\nb", breaks: true) == "<p>a<br />\nb</p>\n"
    assert Erlmark.to_html("```erl\nx\n```", code_class_prefix: "hl-") =~ ~s(class="hl-erl")
    assert_raise ArgumentError, fn -> Erlmark.to_html("x", breaks: "yes") end
    assert_raise ArgumentError, fn -> Erlmark.to_html("x", code_class_prefix: :atom) end
  end

  test "safe mode" do
    assert Erlmark.to_html("<script>x</script>", safe: true) == "<!-- raw HTML omitted -->\n"

    assert Erlmark.to_html("[a](javascript:alert(1))", safe: true) ==
             "<p><a href=\"\">a</a></p>\n"

    assert Erlmark.to_html("<b>x</b>") == "<p><b>x</b></p>\n"
    assert_raise ArgumentError, fn -> Erlmark.to_html("x", safe: 1) end
  end

  test "rejects invalid options" do
    assert_raise ArgumentError, ~r/unknown option/, fn -> Erlmark.to_html("x", bogus: 1) end

    assert_raise ArgumentError, ~r/invalid value/, fn ->
      Erlmark.to_html("x", parallel: :never)
    end

    assert_raise ArgumentError, ~r/unknown extension/, fn ->
      Erlmark.to_html("x", extensions: [:nope])
    end

    assert_raise ArgumentError, ~r/invalid value/, fn -> Erlmark.to_html("x", spawn_above: -1) end
  end
end
