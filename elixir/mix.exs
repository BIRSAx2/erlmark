defmodule ErlmarkEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BIRSAx2/erlmark"

  def project do
    [
      app: :erlmark_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Elixir interface to erlmark, a fast pure Erlang CommonMark and GFM Markdown converter.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      erlmark_dep(),
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # Set ERLMARK_PATH=.. to build against the sibling Erlang sources instead of Hex.
  defp erlmark_dep do
    case System.get_env("ERLMARK_PATH") do
      nil -> {:erlmark, "~> 0.1.1"}
      path -> {:erlmark, path: path, manager: :rebar3}
    end
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url <> "/tree/main/elixir",
        "erlmark" => "https://hex.pm/packages/erlmark"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_url_pattern: @source_url <> "/blob/elixir-v#{@version}/elixir/%{path}#L%{line}"
    ]
  end
end
