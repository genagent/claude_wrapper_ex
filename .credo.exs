%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: %{
        extra: [
          # The Query struct is a flat mapping of `claude` CLI options, one
          # field per flag, so it grows as the CLI does (64 fields after the
          # #328 print flags). Headroom kept above the current field count.
          {Credo.Check.Warning.StructFieldAmount, max_fields: 70}
        ]
      }
    }
  ]
}
