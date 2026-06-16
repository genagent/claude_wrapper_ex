defmodule ClaudeWrapper.IExTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ClaudeWrapper.Error
  alias ClaudeWrapper.IEx, as: CIEx

  # Each ExUnit test runs in its own process, so the process-dictionary
  # state CIEx uses (session / config / history) is naturally isolated
  # between tests -- no shared cleanup needed.

  describe "format_cost/1 (regression: #64)" do
    test "integer 0 does not raise" do
      # ClaudeWrapper.IEx had the same Float.round/2 callsites that
      # crashed in DuplexIEx, in printf paths invoked by `chat`/`say`.
      # Same fix; same regression coverage.
      assert CIEx.format_cost(0) == "$0.0"
    end

    test "non-zero integer cost is coerced and formatted" do
      assert CIEx.format_cost(7) == "$7.0"
    end

    test "float cost is rounded to 4 decimals" do
      assert CIEx.format_cost(0.123456789) == "$0.1235"
    end

    test "nil cost is rendered as ?" do
      assert CIEx.format_cost(nil) == "?"
    end
  end

  describe "configure/1 and config/0" do
    test "config starts empty" do
      assert CIEx.config() == []
    end

    test "configure stores ambient options" do
      assert :ok = CIEx.configure(model: "sonnet", working_dir: "/tmp")
      assert CIEx.config() == [model: "sonnet", working_dir: "/tmp"]
    end

    test "configure merges, last wins" do
      :ok = CIEx.configure(model: "sonnet", max_turns: 3)
      :ok = CIEx.configure(model: "opus")

      config = CIEx.config()
      assert config[:model] == "opus"
      assert config[:max_turns] == 3
    end
  end

  describe "current/0" do
    test "returns nil with no active session" do
      assert CIEx.current() == nil
    end
  end

  describe "say/2 with no active session" do
    test "returns :no_session without raising" do
      output =
        capture_io(fn ->
          assert CIEx.say("anything") == :no_session
        end)

      assert output =~ "No active session"
    end
  end

  describe "chat/2 composition wiring (no live CLI)" do
    test "an attach glob matching nothing renders to a raised :not_found error" do
      # Composition opts must build a %Prompt{} and render it; a glob that
      # matches no files fails at render time, which the helper surfaces by
      # raising ClaudeWrapper.Error -- and it does so before any CLI call,
      # so this is checkable without a real `claude`.
      glob =
        Path.join(System.tmp_dir!(), "cwx_iex_nomatch_#{System.unique_integer([:positive])}/*")

      capture_io(fn ->
        assert_raise Error, fn ->
          CIEx.chat("summarize these", attach: glob)
        end
      end)
    end

    test "the raised error carries the unmatched glob as :not_found" do
      glob =
        Path.join(System.tmp_dir!(), "cwx_iex_nomatch2_#{System.unique_integer([:positive])}/*")

      capture_io(fn ->
        error =
          assert_raise Error, fn ->
            CIEx.chat("go", attach: glob)
          end

        assert error.kind == :not_found
        assert error.reason == glob
      end)
    end
  end

  describe "per-call options never leak into ambient (regression: composition leak)" do
    # A glob that matches nothing makes chat/2 raise :not_found at *render*
    # time -- before any CLI call -- so we can observe exactly what chat/2
    # persisted to ambient without needing a live `claude`.
    setup do
      glob =
        Path.join(System.tmp_dir!(), "cwx_iex_leak_#{System.unique_integer([:positive])}/*")

      {:ok, glob: glob}
    end

    test "a per-call attach is not written back to ambient", %{glob: glob} do
      capture_io(fn ->
        assert_raise Error, fn -> CIEx.chat("go", attach: glob) end
      end)

      # Before the fix, chat/2 wrote its effective opts (incl. :attach) into
      # ambient, so the file silently rode along on the next say/2 turn --
      # re-sending and re-caching it. Per-call opts must not persist.
      assert CIEx.config() == []
    end

    test "a per-call query opt is not written back to ambient either", %{glob: glob} do
      capture_io(fn ->
        assert_raise Error, fn -> CIEx.chat("go", attach: glob, model: "sonnet") end
      end)

      refute Keyword.has_key?(CIEx.config(), :model)
    end

    test "configure/1 composition IS sticky and is applied to chat/2", %{glob: glob} do
      :ok = CIEx.configure(attach: glob)

      capture_io(fn ->
        # the configured attach drove the render -> proves it reached chat/2
        error = assert_raise Error, fn -> CIEx.chat("go") end
        assert error.kind == :not_found
        assert error.reason == glob
      end)

      # ...and it stays configured for later turns (sticky, by opt-in)
      assert CIEx.config()[:attach] == glob
    end
  end
end
