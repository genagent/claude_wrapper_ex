defmodule ClaudeWrapper.StructuredTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Result, Structured}

  defmodule ExtractName do
    @behaviour Structured

    @impl true
    def render(text),
      do: "Extract the person's full name from this text. Text: " <> text

    @impl true
    def schema do
      %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"],
        "additionalProperties" => false
      }
    end
  end

  defmodule BadRender do
    @behaviour Structured

    @impl true
    def render(_input), do: :not_a_prompt

    @impl true
    def schema, do: %{"type" => "object"}
  end

  describe "run/3 (no CLI)" do
    test "an invalid render value errors before any CLI call" do
      assert {:error, {:invalid_render, :not_a_prompt}} = Structured.run(BadRender, "x")
    end
  end

  describe "task callbacks" do
    test "render and schema are plain, testable functions" do
      assert ExtractName.render("hi") =~ "Extract the person's full name"
      assert %{"type" => "object", "required" => ["name"]} = ExtractName.schema()
    end
  end

  describe "run/3 (live)" do
    @tag :integration
    test "extracts a schema-constrained object and returns the Result as audit log" do
      assert {:ok, output, %Result{} = result} =
               Structured.run(ExtractName, "Hi, I'm Ada Lovelace, nice to meet you.")

      assert %{"name" => name} = output
      assert name =~ "Ada"
      # The raw Result is the audit log: it still carries session_id / usage
      # even though the textual `result` is empty under a schema.
      assert is_binary(result.session_id)
    end
  end
end
