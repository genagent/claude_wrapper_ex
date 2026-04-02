import ClaudeWrapper.Workshop

IO.puts("""
\e[36mWorkshop loaded.\e[0m

  \e[33m# set up shared config (do this first)\e[0m
  configure(working_dir: ".", model: "sonnet", context: "...")

  agent(:impl, "You write clean code.", max_turns: 15)
  ask(:impl, "Implement caching for user lookup")
  cast(:impl, "Work on this in the background")
  status()                    \e[33m# dashboard\e[0m
  pipe(:impl, :reviewer, "Review this")
  info(:impl)                 \e[33m# agent details\e[0m
  inspect_agent(:impl)        \e[33m# show CLI command\e[0m
  load()                      \e[33m# load .workshop.exs\e[0m
""")

if File.exists?(".workshop.exs") do
  ClaudeWrapper.Workshop.load()
end
