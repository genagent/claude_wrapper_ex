import ClaudeWrapper.IEx

IO.puts("""
\e[36mClaudeWrapper helpers loaded.\e[0m

  \e[33m# Conversational REPL helpers (per-call subprocess):\e[0m
  chat("explain this codebase", working_dir: ".")
  say("now add tests for the retry module")
  cost()
  history()
  reset()

  \e[33m# Or use the long-lived duplex session for live streaming:\e[0m
  alias ClaudeWrapper.DuplexIEx
  DuplexIEx.start(working_dir: ".")
  DuplexIEx.say("Explain the README briefly.")
  DuplexIEx.close()

  \e[33m# Multi-agent coordination has moved to agent_workshop:\e[0m
  \e[2m# https://hex.pm/packages/agent_workshop\e[0m
""")
