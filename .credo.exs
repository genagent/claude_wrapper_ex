%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: %{
        extra: [
          # The Query struct intentionally maps every `claude` CLI flag, so it
          # grows as the CLI does. Headroom kept above the current field count.
          {Credo.Check.Warning.StructFieldAmount, max_fields: 56}
        ]
      }
    }
  ]
}
