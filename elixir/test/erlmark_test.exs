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
