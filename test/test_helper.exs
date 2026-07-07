# Tests tagged `:forcola` drive the real forcola shim. Exclude them when
# the shim binary is not resolvable so a fresh CI build does not fail on
# an unfetched/unsynced shim (see joshrotenberg/forcola#47); they still
# run locally and once the shim resolves.
forcola_ready? =
  Code.ensure_loaded?(Forcola) and
    match?({:ok, _}, Forcola.Shim.path())

exclude = [:integration] ++ if forcola_ready?, do: [], else: [:forcola]

unless forcola_ready? do
  IO.puts("[test_helper] forcola shim not resolvable; excluding :forcola tests")
end

ExUnit.start(exclude: exclude)
