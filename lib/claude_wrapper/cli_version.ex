defmodule ClaudeWrapper.CliVersion do
  @moduledoc """
  Parse and compare the `claude` CLI's reported version.

  `claude --version` prints a line like `"2.1.71 (Claude Code)"`. This
  module turns that into a comparable `t:t/0` struct and provides the two
  checks a host typically wants:

    * `satisfies_minimum?/2` / `check_version/2` -- a hard floor. Below the
      minimum the wrapper is known to misbehave (missing flags, different
      argument shapes), so the caller should refuse to run.
    * `status_within/3` -- a soft "drift" classification against a
      tested-against `[minimum, maximum]` window. A version above the
      maximum hasn't been verified; semantics may have drifted but the
      wrapper should generally still work, so the caller should warn
      rather than refuse.

  This is the Elixir port of the Rust crate's `CliVersion` /
  `CliVersionStatus` (`../claude-wrapper/src/version.rs`). Versions are
  treated as three-part semver (`major.minor.patch`); any trailing
  metadata such as the `(Claude Code)` suffix is ignored during parsing.

  ## Example

      iex> {:ok, found} = ClaudeWrapper.CliVersion.parse("2.1.71 (Claude Code)")
      iex> ClaudeWrapper.CliVersion.satisfies_minimum?(found, ClaudeWrapper.CliVersion.new(2, 1, 0))
      true
      iex> ClaudeWrapper.CliVersion.status_within(found, ClaudeWrapper.CliVersion.new(2, 1, 0), ClaudeWrapper.CliVersion.new(2, 1, 999))
      :tested
  """

  @enforce_keys [:major, :minor, :patch]
  defstruct [:major, :minor, :patch]

  @type t :: %__MODULE__{
          major: non_neg_integer(),
          minor: non_neg_integer(),
          patch: non_neg_integer()
        }

  @typedoc """
  Classification of a found version against a tested `[minimum, maximum]`
  range. Returned by `status_within/3`.

    * `:tested` -- within the range (inclusive on both ends); safe to run.
    * `{:newer_untested, found, tested_max}` -- above the maximum. The
      wrapper hasn't been verified against this CLI; warn but proceed.
    * `{:older_than_minimum, found, minimum}` -- below the minimum. The
      wrapper is known to behave incorrectly; refuse to run.
  """
  @type status ::
          :tested
          | {:newer_untested, found :: t(), tested_max :: t()}
          | {:older_than_minimum, found :: t(), minimum :: t()}

  @doc """
  Build a version from its three components.

      iex> ClaudeWrapper.CliVersion.new(2, 1, 71)
      %ClaudeWrapper.CliVersion{major: 2, minor: 1, patch: 71}
  """
  @spec new(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def new(major, minor, patch)
      when is_integer(major) and major >= 0 and
             is_integer(minor) and minor >= 0 and
             is_integer(patch) and patch >= 0 do
    %__MODULE__{major: major, minor: minor, patch: patch}
  end

  @doc """
  Parse a version from the output of `claude --version`.

  Accepts a bare `"2.1.71"`, the full `"2.1.71 (Claude Code)"` form, a
  leading `v` (`"v2.1.71"`), and surrounding whitespace. Only the first
  whitespace-delimited token is considered, and it must be exactly three
  dot-separated non-negative integers.

  Returns `{:error, %ClaudeWrapper.Error{kind: :invalid_version}}` for
  anything else, with the original (untrimmed) string carried in
  `:reason`.

      iex> ClaudeWrapper.CliVersion.parse("  2.1.71 (Claude Code)\\n")
      {:ok, %ClaudeWrapper.CliVersion{major: 2, minor: 1, patch: 71}}

      iex> ClaudeWrapper.CliVersion.parse("2.1")
      {:error, %ClaudeWrapper.Error{kind: :invalid_version, reason: "2.1"}}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, ClaudeWrapper.Error.t()}
  def parse(output) when is_binary(output) do
    token =
      output
      |> String.split()
      |> List.first()
      |> strip_leading_v()

    parse_token(token, output)
  end

  defp strip_leading_v(nil), do: ""
  defp strip_leading_v("v" <> rest), do: rest
  defp strip_leading_v(token), do: token

  defp parse_token(token, original) do
    case String.split(token, ".") do
      [major, minor, patch] -> build_from_parts(major, minor, patch, original)
      _ -> {:error, ClaudeWrapper.Error.new(:invalid_version, reason: original)}
    end
  end

  defp build_from_parts(major, minor, patch, original) do
    with {:ok, major} <- parse_component(major),
         {:ok, minor} <- parse_component(minor),
         {:ok, patch} <- parse_component(patch) do
      {:ok, new(major, minor, patch)}
    else
      :error -> {:error, ClaudeWrapper.Error.new(:invalid_version, reason: original)}
    end
  end

  defp parse_component(part) do
    case Integer.parse(part) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  @doc """
  Render a version as `"major.minor.patch"`.

  The `String.Chars` protocol is also implemented, so `to_string/1` and
  string interpolation work too.

      iex> ClaudeWrapper.CliVersion.to_string(ClaudeWrapper.CliVersion.new(2, 1, 71))
      "2.1.71"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{major: major, minor: minor, patch: patch}) do
    "#{major}.#{minor}.#{patch}"
  end

  @doc """
  Compare two versions, returning `:lt`, `:eq`, or `:gt`.

  Ordering is by `major`, then `minor`, then `patch`. The shape is
  suitable as the second argument to `Enum.sort/2`.

      iex> Enum.sort(
      ...>   [ClaudeWrapper.CliVersion.new(2, 1, 71), ClaudeWrapper.CliVersion.new(2, 1, 0)],
      ...>   ClaudeWrapper.CliVersion
      ...> )
      [%ClaudeWrapper.CliVersion{major: 2, minor: 1, patch: 0}, %ClaudeWrapper.CliVersion{major: 2, minor: 1, patch: 71}]
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    cond do
      tuple(a) < tuple(b) -> :lt
      tuple(a) > tuple(b) -> :gt
      true -> :eq
    end
  end

  defp tuple(%__MODULE__{major: major, minor: minor, patch: patch}), do: {major, minor, patch}

  @doc """
  True when `found` is greater than or equal to `minimum`.

      iex> v = ClaudeWrapper.CliVersion.new(2, 1, 71)
      iex> ClaudeWrapper.CliVersion.satisfies_minimum?(v, ClaudeWrapper.CliVersion.new(2, 1, 0))
      true
      iex> ClaudeWrapper.CliVersion.satisfies_minimum?(v, ClaudeWrapper.CliVersion.new(2, 2, 0))
      false
  """
  @spec satisfies_minimum?(t(), t()) :: boolean()
  def satisfies_minimum?(%__MODULE__{} = found, %__MODULE__{} = minimum) do
    compare(found, minimum) != :lt
  end

  @doc """
  Classify `found` against a tested-against `[minimum, maximum]` range
  (both ends inclusive). See `t:status/0` for the three outcomes.

      iex> tested = ClaudeWrapper.CliVersion.status_within(
      ...>   ClaudeWrapper.CliVersion.new(2, 1, 143),
      ...>   ClaudeWrapper.CliVersion.new(2, 1, 0),
      ...>   ClaudeWrapper.CliVersion.new(2, 1, 999)
      ...> )
      iex> tested
      :tested
  """
  @spec status_within(t(), t(), t()) :: status()
  def status_within(%__MODULE__{} = found, %__MODULE__{} = minimum, %__MODULE__{} = maximum) do
    cond do
      compare(found, minimum) == :lt -> {:older_than_minimum, found, minimum}
      compare(found, maximum) == :gt -> {:newer_untested, found, maximum}
      true -> :tested
    end
  end

  @doc """
  Enforce a minimum version as a tagged-tuple result.

  Returns `:ok` when `found` satisfies `minimum`, otherwise
  `{:error, %ClaudeWrapper.Error{kind: :version_mismatch}}` whose
  `:reason` is `%{found: found, minimum: minimum}`.

      iex> v = ClaudeWrapper.CliVersion.new(2, 1, 71)
      iex> ClaudeWrapper.CliVersion.check_version(v, ClaudeWrapper.CliVersion.new(2, 1, 0))
      :ok
      iex> ClaudeWrapper.CliVersion.check_version(v, ClaudeWrapper.CliVersion.new(2, 2, 0))
      {:error, %ClaudeWrapper.Error{kind: :version_mismatch, reason: %{found: %ClaudeWrapper.CliVersion{major: 2, minor: 1, patch: 71}, minimum: %ClaudeWrapper.CliVersion{major: 2, minor: 2, patch: 0}}}}
  """
  @spec check_version(t(), t()) :: :ok | {:error, ClaudeWrapper.Error.t()}
  def check_version(%__MODULE__{} = found, %__MODULE__{} = minimum) do
    if satisfies_minimum?(found, minimum) do
      :ok
    else
      {:error,
       ClaudeWrapper.Error.new(:version_mismatch, reason: %{found: found, minimum: minimum})}
    end
  end

  defimpl String.Chars do
    def to_string(version), do: ClaudeWrapper.CliVersion.to_string(version)
  end
end
