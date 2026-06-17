import ClaudeWrapper.IEx
alias ClaudeWrapper.Prompt

IO.puts("""
\e[36mClaudeWrapper helpers loaded.\e[0m

  \e[33m# Talk to Claude (per-call subprocess):\e[0m
  chat("explain this codebase", working_dir: ".")
  say("now add tests for the retry module")
  cost(); history(); reset()

  \e[33m# Compose a prompt -- attach files / a git diff (per-call):\e[0m
  chat("review my change", attach: "lib/**/*.ex", git_diff: true)
  Prompt.new("summarize") |> Prompt.attach("mix.exs") |> Prompt.render!()

  \e[33m# Sticky defaults, prior sessions, branching:\e[0m
  configure(model: "sonnet", working_dir: ".")
  sessions(); pick(); resume("<session-id>"); fork("branch this idea")

  \e[33m# Long-lived duplex session (live token streaming):\e[0m
  alias ClaudeWrapper.DuplexIEx
  DuplexIEx.start(working_dir: ".")
  DuplexIEx.say("Explain the README briefly."); DuplexIEx.close()

  \e[33m# Multi-agent coordination lives in agent_workshop:\e[0m
  \e[2m# https://hex.pm/packages/agent_workshop\e[0m
""")
