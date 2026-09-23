defmodule Dagre.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jeremylightsmith/dagre_ex"

  def project do
    [
      app: :dagre_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "A dependency-free Elixir port of the dagre layered (Sugiyama) graph layout core: " <>
          "geometry in, geometry out.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application, do: []

  def cli, do: [preferred_envs: [precommit: :test]]

  # No runtime dependencies — by design. Only tooling.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "format",
        "credo --strict",
        "test --warnings-as-errors"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "dagre (the JavaScript original)" => "https://github.com/dagrejs/dagre"
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "Dagre",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}"
    ]
  end
end
