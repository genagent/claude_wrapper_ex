# Tests tagged `:forcola` drive the real forcola shim. Exclude them when
# the shim binary is not resolvable (forcola absent, an unsupported
# platform, or no network to fetch the precompiled shim) so the suite
# stays green; they run wherever the shim resolves.
forcola_ready? =
  Code.ensure_loaded?(Forcola) and
    match?({:ok, _}, Forcola.Shim.path())

exclude = [:integration] ++ if forcola_ready?, do: [], else: [:forcola]

unless forcola_ready? do
  IO.puts("[test_helper] forcola shim not resolvable; excluding :forcola tests")
end

ExUnit.start(exclude: exclude)
