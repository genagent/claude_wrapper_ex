defmodule ClaudeWrapper.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/joshrotenberg/claude_wrapper_ex"

  def project do
    [
      app: :claude_wrapper,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      name: "ClaudeWrapper",
      description: "Elixir wrapper for the Claude Code CLI"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:anubis_mcp, "~> 1.0", optional: true},
      {:bandit, "~> 1.0", optional: true},
      {:plug, "~> 1.16", optional: true},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "ClaudeWrapper",
      source_url: @source_url
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs),
      maintainers: ["Josh Rotenberg"]
    ]
  end
end
