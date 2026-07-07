defmodule ClaudeWrapper.ErrorTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Error

  doctest ClaudeWrapper.Error

  describe "new/2" do
    test "builds an error with just a kind" do
      error = Error.new(:no_session)

      assert %Error{kind: :no_session} = error
      assert error.message == nil
      assert error.reason == nil
      assert error.exit_code == nil
      assert error.stdout == nil
      assert error.stderr == nil
    end

    test "carries optional fields through" do
      error =
        Error.new(:auth,
          reason: :invalid_credentials,
          exit_code: 1,
          stdout: "out",
          stderr: "err",
          message: "custom"
        )

      assert %Error{
               kind: :auth,
               reason: :invalid_credentials,
               exit_code: 1,
               stdout: "out",
               stderr: "err",
               message: "custom"
             } = error
    end

    test "is an exception struct" do
      assert Exception.exception?(Error.new(:timeout, reason: 1_000))
    end
  end

  describe "command_failed/3" do
    test "sets kind, exit_code and stdout" do
      assert %Error{kind: :command_failed, exit_code: 2, stdout: "boom", stderr: nil} =
               Error.command_failed(2, "boom")
    end

    test "captures stderr when given" do
      assert %Error{kind: :command_failed, exit_code: 2, stdout: "out", stderr: "err"} =
               Error.command_failed(2, "out", "err")
    end
  end

  describe "timeout/1" do
    test "carries the elapsed ms in :reason" do
      assert %Error{kind: :timeout, reason: 30_000} = Error.timeout(30_000)
    end
  end

  describe "json/2" do
    test "wraps a decode reason" do
      assert %Error{kind: :json, reason: :reason, stdout: nil} = Error.json(:reason)
    end

    test "optionally carries the raw stdout" do
      assert %Error{kind: :json, reason: :reason, stdout: "{bad"} = Error.json(:reason, "{bad")
    end
  end

  describe "io/1" do
    test "wraps an underlying reason" do
      assert %Error{kind: :io, reason: :enoent} = Error.io(:enoent)
    end
  end

  describe "message/1" do
    test "returns an explicit message verbatim" do
      assert Error.message(Error.new(:command_failed, message: "explicit")) == "explicit"
    end

    test "derives a default for :command_failed from the exit code" do
      assert Error.message(Error.command_failed(2, "boom")) == "claude exited with status 2"
    end

    test "derives a default for :timeout from the elapsed ms" do
      assert Error.message(Error.timeout(5_000)) == "claude timed out after 5000ms"
    end

    test "derives a default for :max_turns_exceeded" do
      assert Error.message(Error.new(:max_turns_exceeded)) =~ "maximum number of turns"

      assert Error.message(Error.new(:max_turns_exceeded, reason: %{cap: 3})) =~
               "--max-turns cap of 3"
    end

    test "derives a default for :max_budget_exceeded" do
      assert Error.message(Error.new(:max_budget_exceeded)) =~ "maximum budget"

      assert Error.message(Error.new(:max_budget_exceeded, reason: %{cap: 5.0})) =~
               "--max-budget-usd cap of $5.00"
    end

    test "derives a default for :not_found with and without a reason" do
      assert Error.message(Error.new(:not_found, reason: "auditor")) =~ "auditor"
      assert Error.message(Error.new(:not_found)) == "not found"
    end

    test "derives a default for :version_mismatch from the reason map" do
      found = %ClaudeWrapper.CliVersion{major: 2, minor: 1, patch: 71}
      minimum = %ClaudeWrapper.CliVersion{major: 2, minor: 2, patch: 0}

      message =
        Error.message(Error.new(:version_mismatch, reason: %{found: found, minimum: minimum}))

      assert message =~ "2.1.71"
      assert message =~ "2.2.0"
    end

    test "derives a default for :budget_exceeded from the reason map" do
      message =
        Error.message(Error.new(:budget_exceeded, reason: %{total_usd: 5.0, max_usd: 4.0}))

      assert message =~ "5.0"
      assert message =~ "4.0"
    end

    test "falls back to a generic message for an unmapped kind" do
      assert Error.message(Error.new(:duplex_closed)) =~ "duplex"
    end
  end

  describe "raising" do
    test "raise/2 accepts the exception with options" do
      assert_raise Error, "claude timed out after 1000ms", fn ->
        raise Error, kind: :timeout, reason: 1_000
      end
    end

    test "the struct can be raised directly and surfaces its message" do
      error = Error.command_failed(7, "nope")

      raised =
        assert_raise Error, fn -> raise error end

      assert Exception.message(raised) == "claude exited with status 7"
    end
  end
end
