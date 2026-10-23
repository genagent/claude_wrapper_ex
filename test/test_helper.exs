# Tests tagged `:forcola` drive the real forcola shim. Exclude them when
# the shim binary is not resolvable (forcola absent, an unsupported
# platform, or no network to fetch the precompiled shim). This applies only
# to legacy tests; the required evidence suite is checked separately below.
forcola_ready? =
  Code.ensure_loaded?(Forcola) and
    match?({:ok, _}, Forcola.Shim.path())

# Evidenced execution requires the released Forcola 0.7 contract and a
# matching shim. Those tests deliberately run even when support is missing:
# an absent required contract must fail, not silently exclude coverage.
exclude = if forcola_ready?, do: [:integration], else: [:integration, :forcola]

unless forcola_ready? do
  IO.puts("[test_helper] forcola shim not resolvable; excluding legacy :forcola tests")
end

ExUnit.start(exclude: exclude)
