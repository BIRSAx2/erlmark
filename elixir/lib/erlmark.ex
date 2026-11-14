defmodule Erlmark do
  @moduledoc """
  Fast Markdown to HTML conversion for Elixir.

  A thin wrapper around [erlmark](https://hex.pm/packages/erlmark), a pure Erlang
  CommonMark 0.31.2 converter with the GFM tables, strikethrough and task-list
  extensions. There are no NIFs or system dependencies.

      iex> Erlmark.to_html("# Hello *world*")
      "<h1>Hello <em>world</em></h1>\\n"

  Raw HTML in the input is passed through unchanged, as CommonMark requires. Sanitise
  the output if the input is untrusted.
  """

  @typedoc "An opt-in GFM extension."
  @type extension :: :autolink | :tagfilter

  @typedoc """
  A conversion option. See `to_html/2`.
  """
  @type option ::
          {:spawn_above, non_neg_integer() | :infinity}
          | {:parallel, false | :auto | pos_integer()}
          | {:extensions, [extension()]}
          | {:breaks, boolean()}
          | {:safe, boolean()}
          | {:code_class_prefix, String.t()}

  @extensions [:autolink, :tagfilter]

  @doc """
  Converts Markdown to HTML.

  `markdown` is a string or any iodata. Options:

    * `:extensions` - a list of opt-in GFM extensions. `:autolink` turns bare `www.`,
      `http(s)://` and `ftp://` URLs and e-mail addresses into links. `:tagfilter`
      escapes `<script>`, `<style>` and similar tags. Conversion with extensions is
      always sequential. Defaults to `[]`.

    * `:parallel` - `:auto` (all online schedulers) or a number of schedulers to
      convert large documents on. The output is identical to sequential conversion.
      Documents under 16 KB are never split. Defaults to `false`.

    * `:spawn_above` - inputs larger than this many bytes are converted in a
      short-lived process with a pre-sized heap, which avoids most garbage
      collection. `:infinity` always converts in the calling process. Defaults to `256`.

    * `:safe` - safe output for untrusted input. Raw HTML is replaced by
      `<!-- raw HTML omitted -->`, and link and image destinations using the `javascript:`,
      `vbscript:`, `file:` or `data:` schemes become empty (`data:` is kept for PNG, GIF,
      JPEG and WebP images). Defaults to `false`.

    * `:breaks` - render a line break inside a paragraph as `<br />`, as chat and comment
      systems expect. Defaults to `false`.

    * `:code_class_prefix` - prefix of the class on fenced code blocks that have an info
      string. Defaults to `"language-"`.

  Raises `ArgumentError` for an unknown option or an invalid value.

  ## Examples

      iex> Erlmark.to_html("*emphasis* and **strong**")
      "<p><em>emphasis</em> and <strong>strong</strong></p>\\n"

      iex> Erlmark.to_html("visit www.example.com", extensions: [:autolink])
      "<p>visit <a href=\\"http://www.example.com\\">www.example.com</a></p>\\n"

      iex> Erlmark.to_html("<script>alert(1)</script>", safe: true)
      "<!-- raw HTML omitted -->\\n"

      iex> Erlmark.to_html("a\\nb", breaks: true)
      "<p>a<br />\\nb</p>\\n"

      iex> Erlmark.to_html("| a |\\n|---|\\n| 1 |")
      "<table>\\n<thead>\\n<tr>\\n<th>a</th>\\n</tr>\\n</thead>\\n<tbody>\\n<tr>\\n<td>1</td>\\n</tr>\\n</tbody>\\n</table>\\n"
  """
  @spec to_html(iodata(), [option()]) :: String.t()
  def to_html(markdown, opts \\ []) when is_list(opts) do
    :erlmark.to_html(markdown, Enum.map(opts, &validate!/1))
  end

  defp validate!({:spawn_above, :infinity} = opt), do: opt
  defp validate!({:spawn_above, n} = opt) when is_integer(n) and n >= 0, do: opt
  defp validate!({:breaks, b} = opt) when is_boolean(b), do: opt
  defp validate!({:safe, b} = opt) when is_boolean(b), do: opt
  defp validate!({:code_class_prefix, p} = opt) when is_binary(p), do: opt
  defp validate!({:parallel, p} = opt) when p in [false, :auto], do: opt
  defp validate!({:parallel, n} = opt) when is_integer(n) and n >= 1, do: opt

  defp validate!({:extensions, exts} = opt) when is_list(exts) do
    case Enum.reject(exts, &(&1 in @extensions)) do
      [] ->
        opt

      bad ->
        raise ArgumentError,
              "unknown extension(s) #{inspect(bad)}, expected #{inspect(@extensions)}"
    end
  end

  defp validate!({key, value})
       when key in [:spawn_above, :parallel, :extensions, :breaks, :safe, :code_class_prefix] do
    raise ArgumentError, "invalid value #{inspect(value)} for option #{inspect(key)}"
  end

  defp validate!(other) do
    raise ArgumentError,
          "unknown option #{inspect(other)}, expected a keyword list with :spawn_above, :parallel, :extensions, :breaks, :safe or :code_class_prefix"
  end
end
