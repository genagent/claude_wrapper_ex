defmodule ClaudeWrapper.MixProject do
  use Mix.Project

  @version "0.14.0"
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
      dialyzer: [
        plt_file: {:no_warn, "_build/dev/dialyxir_#{System.otp_release()}.plt"},
        plt_add_apps: [:mix]
      ]
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
      # Optional: leak-free subprocess control (process-group kill on
      # timeout / BEAM death). Enables Runner.Forcola and
      # DuplexSession.Adapter.Forcola. See "Leak-free execution" in the
      # README. POSIX-only; absent it, the default Port paths are used.
      {:forcola, "~> 0.3", optional: true},
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
        "Driving claude": [
          ClaudeWrapper.DuplexSession,
          ClaudeWrapper.DuplexIEx,
          ClaudeWrapper.Conversation,
          ClaudeWrapper,
          ClaudeWrapper.Query,
          ClaudeWrapper.Session,
          ClaudeWrapper.SessionServer,
          ClaudeWrapper.IEx
        ],
        "Prompt building & structured output": [
          ClaudeWrapper.Prompt,
          ClaudeWrapper.Stream,
          ClaudeWrapper.Structured
        ],
        "Config, results, support": [
          ClaudeWrapper.Config,
          ClaudeWrapper.Result,
          ClaudeWrapper.StreamEvent,
          ClaudeWrapper.Error,
          ClaudeWrapper.McpConfig,
          ClaudeWrapper.Retry,
          ClaudeWrapper.Telemetry,
          ClaudeWrapper.Budget,
          ClaudeWrapper.ToolPattern,
          ClaudeWrapper.CliVersion,
          ClaudeWrapper.DangerousClient,
          ClaudeWrapper.Auth,
          ClaudeWrapper.Test,
          ClaudeWrapper.Bundled
        ],
        "Subprocess execution": [
          ClaudeWrapper.Runner,
          ClaudeWrapper.Runner.Port,
          ClaudeWrapper.Runner.Forcola
        ],
        "DuplexSession transport adapter": [
          ClaudeWrapper.DuplexSession.Adapter,
          ClaudeWrapper.DuplexSession.Adapter.Port,
          ClaudeWrapper.DuplexSession.Adapter.Forcola,
          ClaudeWrapper.DuplexSession.Adapter.Test
        ],
        "~/.claude introspection & agent authoring": [
          ClaudeWrapper.History,
          ClaudeWrapper.Settings,
          ClaudeWrapper.Agents,
          ClaudeWrapper.Skills,
          ClaudeWrapper.Jobs,
          ClaudeWrapper.Worktrees
        ],
        "Command surface": [
          ClaudeWrapper.Command,
          ClaudeWrapper.Commands.Auth,
          ClaudeWrapper.Commands.Agents,
          ClaudeWrapper.Commands.Doctor,
          ClaudeWrapper.Commands.Mcp,
          ClaudeWrapper.Commands.Plugin,
          ClaudeWrapper.Commands.Marketplace,
          ClaudeWrapper.Commands.AutoMode,
          ClaudeWrapper.Commands.Install,
          ClaudeWrapper.Commands.Update,
          ClaudeWrapper.Commands.Project,
          ClaudeWrapper.Commands.Ultrareview,
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
