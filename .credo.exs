%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: %{
        extra: [
          # The Query struct intentionally maps every CLI flag (37 fields).
          {Credo.Check.Warning.StructFieldAmount, max_fields: 40}
        ]
      }
    }
  ]
}
