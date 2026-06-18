defmodule ClaudeWrapper.StructuredTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Error, Result, Structured}

  defmodule Person do
    defstruct [:name]
  end

  defmodule ExtractName do
    @behaviour Structured

    @impl true
    def render(text), do: "Extract the person's full name from this text. Text: " <> text

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

  defmodule ExtractPerson do
    @behaviour Structured

    @impl true
    def render(text), do: "Extract the person's full name from this text. Text: " <> text

    @impl true
    def schema, do: ExtractName.schema()

    @impl true
    def parse(%{"name" => name}), do: {:ok, %Person{name: name}}
    def parse(other), do: {:error, {:unexpected_shape, other}}
  end

  defmodule BadRender do
    @behaviour Structured

    @impl true
    def render(_input), do: :not_a_prompt

    @impl true
    def schema, do: %{"type" => "object"}
  end

  describe "run/3 (no CLI)" do
    test "an invalid render value is a ClaudeWrapper.Error before any CLI call" do
      assert {:error, %Error{kind: :invalid_render, reason: :not_a_prompt}} =
               Structured.run(BadRender, "x")
    end
  end

  describe "task callbacks" do
    test "render and schema are plain, testable functions" do
      assert ExtractName.render("hi") =~ "Extract the person's full name"
      assert %{"type" => "object", "required" => ["name"]} = ExtractName.schema()
    end

    test "parse/1 maps the validated object into a domain struct" do
      assert {:ok, %Person{name: "Ada Lovelace"}} =
               ExtractPerson.parse(%{"name" => "Ada Lovelace"})

      assert {:error, {:unexpected_shape, _}} = ExtractPerson.parse(%{"nope" => 1})
    end
  end

  describe "run/3 (live)" do
    @tag :integration
    test "extracts, parses into a struct, and returns the Result as audit log" do
      assert {:ok, %Person{name: name}, %Result{} = result} =
               Structured.run(ExtractPerson, "Hi, I'm Ada Lovelace, nice to meet you.")

      assert name =~ "Ada"
      # The raw Result is the audit log: session_id is present even though
      # the textual `result` is empty under a schema.
      assert is_binary(result.session_id)
    end
  end
end
