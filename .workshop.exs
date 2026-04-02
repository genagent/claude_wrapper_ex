configure(
  working_dir: ".",
  model: "sonnet",
  permission_mode: :bypass_permissions,
  context: "claude_wrapper_ex - Elixir wrapper for Claude CLI. Mix project.",
  mcp: [port: 4222]
)

agent(:impl, "You write clean, well-tested Elixir code.", max_turns: 15)

agent(:reviewer, "Code review only. Do not modify files.",
  model: "opus",
  allowed_tools: ["Read", "Bash"]
)

agent(:tests, "Focus on test coverage and edge cases.", permission_mode: :bypass_permissions)
agent(:docs, "Write and improve documentation.", allowed_tools: ["Read", "Write"])
