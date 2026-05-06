defmodule ClaudeWrapper.IExTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.IEx, as: CIEx

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
end
