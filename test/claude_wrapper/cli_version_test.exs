defmodule ClaudeWrapper.CliVersionTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.CliVersion

  doctest CliVersion

  describe "parse/1" do
    test "parses a bare version" do
      assert {:ok, v} = CliVersion.parse("2.1.71")
      assert v == CliVersion.new(2, 1, 71)
      assert v.major == 2
      assert v.minor == 1
      assert v.patch == 71
    end

    test "parses the (Claude Code) suffix" do
      assert {:ok, %CliVersion{major: 2, minor: 1, patch: 71} = v} =
               CliVersion.parse("2.1.71 (Claude Code)")

      assert v == CliVersion.new(2, 1, 71)
    end

    test "trims surrounding whitespace and a trailing newline" do
      assert {:ok, v} = CliVersion.parse("  2.1.71 (Claude Code)\n")
      assert v == CliVersion.new(2, 1, 71)
    end

    test "accepts a leading v" do
      assert {:ok, v} = CliVersion.parse("v2.1.71")
      assert v == CliVersion.new(2, 1, 71)
    end

    test "rejects non-version text, carrying the original string" do
      assert {:error, %ClaudeWrapper.Error{kind: :invalid_version, reason: "not-a-version"}} =
               CliVersion.parse("not-a-version")
    end

    test "rejects a two-part version" do
      assert {:error, %ClaudeWrapper.Error{kind: :invalid_version, reason: "2.1"}} =
               CliVersion.parse("2.1")
    end

    test "rejects a non-numeric component" do
      assert {:error, %ClaudeWrapper.Error{kind: :invalid_version, reason: "2.1.x"}} =
               CliVersion.parse("2.1.x")
    end

    test "rejects a four-part version" do
      assert {:error, %ClaudeWrapper.Error{kind: :invalid_version, reason: "1.2.3.4"}} =
               CliVersion.parse("1.2.3.4")
    end

    test "rejects an empty string" do
      assert {:error, %ClaudeWrapper.Error{kind: :invalid_version, reason: ""}} =
               CliVersion.parse("")
    end

    test "the error keeps the untrimmed original" do
      assert {:error, %ClaudeWrapper.Error{kind: :invalid_version, reason: "  bad\n"}} =
               CliVersion.parse("  bad\n")
    end
  end

  describe "to_string/1 and String.Chars" do
    test "renders major.minor.patch" do
      assert CliVersion.to_string(CliVersion.new(2, 1, 71)) == "2.1.71"
    end

    test "is usable in string interpolation" do
      assert "#{CliVersion.new(2, 1, 71)}" == "2.1.71"
    end

    test "round-trips through parse" do
      assert {:ok, v} = CliVersion.parse(CliVersion.to_string(CliVersion.new(3, 0, 5)))
      assert v == CliVersion.new(3, 0, 5)
    end
  end

  describe "compare/2 and ordering" do
    test "orders by major, then minor, then patch" do
      v1 = CliVersion.new(2, 0, 0)
      v2 = CliVersion.new(2, 1, 0)
      v3 = CliVersion.new(2, 1, 71)
      v4 = CliVersion.new(3, 0, 0)

      assert CliVersion.compare(v1, v2) == :lt
      assert CliVersion.compare(v2, v3) == :lt
      assert CliVersion.compare(v3, v4) == :lt
      assert CliVersion.compare(v1, v4) == :lt
    end

    test "reports :gt for the reverse direction" do
      assert CliVersion.compare(CliVersion.new(3, 0, 0), CliVersion.new(2, 1, 71)) == :gt
      assert CliVersion.compare(CliVersion.new(2, 1, 0), CliVersion.new(2, 0, 9)) == :gt
      assert CliVersion.compare(CliVersion.new(2, 1, 71), CliVersion.new(2, 1, 0)) == :gt
    end

    test "reports :eq for equal versions" do
      assert CliVersion.compare(CliVersion.new(2, 1, 71), CliVersion.new(2, 1, 71)) == :eq
    end

    test "drives Enum.sort/2 as a sorter module" do
      versions = [
        CliVersion.new(3, 0, 0),
        CliVersion.new(2, 1, 0),
        CliVersion.new(2, 1, 71),
        CliVersion.new(2, 0, 0)
      ]

      assert Enum.sort(versions, CliVersion) == [
               CliVersion.new(2, 0, 0),
               CliVersion.new(2, 1, 0),
               CliVersion.new(2, 1, 71),
               CliVersion.new(3, 0, 0)
             ]
    end
  end

  describe "satisfies_minimum?/2" do
    test "true at and above the minimum, false below" do
      v = CliVersion.new(2, 1, 71)

      assert CliVersion.satisfies_minimum?(v, CliVersion.new(2, 0, 0))
      assert CliVersion.satisfies_minimum?(v, CliVersion.new(2, 1, 71))
      refute CliVersion.satisfies_minimum?(v, CliVersion.new(2, 2, 0))
      refute CliVersion.satisfies_minimum?(v, CliVersion.new(3, 0, 0))
    end
  end

  describe "status_within/3" do
    @min CliVersion.new(2, 1, 0)
    @max CliVersion.new(2, 1, 999)

    test "tested at the minimum boundary" do
      assert CliVersion.status_within(CliVersion.new(2, 1, 0), @min, @max) == :tested
    end

    test "tested at the maximum boundary" do
      assert CliVersion.status_within(CliVersion.new(2, 1, 999), @min, @max) == :tested
    end

    test "tested in the middle of the range" do
      assert CliVersion.status_within(CliVersion.new(2, 1, 143), @min, @max) == :tested
    end

    test "newer_untested above the maximum" do
      found = CliVersion.new(2, 2, 0)
      assert CliVersion.status_within(found, @min, @max) == {:newer_untested, found, @max}
    end

    test "older_than_minimum below the minimum" do
      found = CliVersion.new(2, 0, 99)
      assert CliVersion.status_within(found, @min, @max) == {:older_than_minimum, found, @min}
    end
  end

  describe "check_version/2" do
    test "returns :ok when the minimum is satisfied" do
      v = CliVersion.new(2, 1, 71)

      assert CliVersion.check_version(v, CliVersion.new(2, 0, 0)) == :ok
      assert CliVersion.check_version(v, CliVersion.new(2, 1, 71)) == :ok
    end

    test "returns a tagged mismatch when below the minimum" do
      found = CliVersion.new(2, 1, 71)
      minimum = CliVersion.new(2, 2, 0)

      assert {:error,
              %ClaudeWrapper.Error{
                kind: :version_mismatch,
                reason: %{found: ^found, minimum: ^minimum}
              }} = CliVersion.check_version(found, minimum)
    end
  end
end
