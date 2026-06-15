defmodule ClaudeWrapper.MixProject do
  use Mix.Project

  @version "0.8.0"
  @source_url "https://github.com/genagent/claude_wrapper_ex"

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
      description: "Elixir wrapper for the Claude Code CLI",
      dialyzer: [plt_file: {:no_warn, "_build/dev/dialyxir_#{System.otp_release()}.plt"}]
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
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "Long-lived sessions": [
          ClaudeWrapper.DuplexSession,
          ClaudeWrapper.DuplexIEx
        ],
        "One-shot / per-call": [
          ClaudeWrapper,
          ClaudeWrapper.Query,
          ClaudeWrapper.Session,
          ClaudeWrapper.SessionServer,
          ClaudeWrapper.IEx
        ],
        "Shared infrastructure": [
          ClaudeWrapper.Config,
          ClaudeWrapper.Result,
          ClaudeWrapper.StreamEvent,
          ClaudeWrapper.McpConfig,
          ClaudeWrapper.Retry,
          ClaudeWrapper.Telemetry
        ],
        "CLI subcommand wrappers": [
          ClaudeWrapper.Command,
          ClaudeWrapper.Commands.Auth,
          ClaudeWrapper.Commands.Agents,
          ClaudeWrapper.Commands.Doctor,
          ClaudeWrapper.Commands.Mcp,
          ClaudeWrapper.Commands.Plugin,
          ClaudeWrapper.Commands.Marketplace,
          ClaudeWrapper.Commands.Version
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs),
      maintainers: ["Josh Rotenberg"]
    ]
  end
end
