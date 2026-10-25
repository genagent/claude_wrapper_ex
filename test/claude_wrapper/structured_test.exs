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

  defmodule BadParse do
    @behaviour Structured

    @impl true
    def render(text), do: text

    @impl true
    def schema, do: ExtractName.schema()

    @impl true
    def parse(%{"name" => name}), do: %Person{name: name}
  end

  @fake_claude Path.expand("../fixtures/fake_claude", __DIR__)

  # Run a task against the fake executable, returning the outcome and the
  # argv of each process it started.
  defp run_fake(scenario, module \\ ExtractPerson) do
    calls =
      Path.join(
        System.tmp_dir!(),
        "structured-fake-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(calls) end)

    outcome =
      Structured.run(module, "Hi, I'm Ada Lovelace.",
        binary: @fake_claude,
        timeout: 5_000,
        env: [{"FAKE_CLAUDE_SCENARIO", scenario}, {"FAKE_CLAUDE_CALLS", calls}]
      )

    invocations =
      if File.exists?(calls),
        do: calls |> File.read!() |> String.split("\n", trim: true),
        else: []

    {outcome, invocations}
  end

  describe "run/3 (fake executable)" do
    test "decodes an object into the domain value and passes the schema" do
      assert {{:ok, %Person{name: "Ada Lovelace"}, %Result{session_id: "fake-session"}}, [argv]} =
               run_fake("object")

      assert argv =~ ~s(--json-schema {"additionalProperties":false)
    end

    test "returns an array unchanged when the module has no parse/1" do
      assert {{:ok, [%{"name" => "Ada"}, %{"name" => "Grace"}], %Result{}}, [_]} =
               run_fake("array", ExtractName)
    end

    test "missing and null output are :no_structured_output" do
      for scenario <- ["missing", "null"] do
        assert {{:error, %Error{kind: :no_structured_output, reason: %Result{}}}, [_]} =
                 run_fake(scenario)
      end
    end

    test "a non-object, non-array output is :invalid_structured_output" do
      assert {{:error, %Error{kind: :invalid_structured_output}}, [_]} = run_fake("scalar")
    end

    test "a native error result is never decoded, even with a partial object" do
      assert {{:error, %Error{kind: :structured_result_error, reason: %Result{} = result}}, [_]} =
               run_fake("native_error")

      assert result.extra["subtype"] == "error_max_structured_output_retries"
      assert Result.structured_output(result) == %{"name" => "partial"}
    end

    test "malformed stdout is a :json error" do
      assert {{:error, %Error{kind: :json}}, [_]} = run_fake("malformed")
    end

    test "a crash without output is :command_failed" do
      assert {{:error, %Error{kind: :command_failed, exit_code: 2}}, [_]} = run_fake("crash")
    end

    test "a wrong domain shape returns the parser's error" do
      assert {{:error, {:unexpected_shape, [_ | _]}}, [_]} = run_fake("array")
    end

    test "a parser returning a bare value is :invalid_parse_result" do
      assert {{:error, %Error{kind: :invalid_parse_result, reason: %Person{}}}, [_]} =
               run_fake("object", BadParse)
    end
  end

  describe "decode/2" do
    test "decodes a resident session turn without another call" do
      {:ok, session, stub} = ClaudeWrapper.Test.start_session()

      ClaudeWrapper.Test.stub(stub, [
        ClaudeWrapper.Test.result(structured_output: %{"name" => "Ada"}, session_id: "s-1")
      ])

      {:ok, result} = ClaudeWrapper.DuplexSession.send(session, "who?")

      assert {:ok, %Person{name: "Ada"}, ^result} = Structured.decode(ExtractPerson, result)
      assert {:ok, "Ada", ^result} = Structured.decode(&{:ok, &1["name"]}, result)
    end

    test "uses parse/1 from a module not yet referenced" do
      result = Result.from_json(%{"structured_output" => %{"name" => "Ada"}})
      assert {:ok, %Person{}, _} = Structured.decode(ExtractPerson, result)
    end

    test "rejects an error result before parsing" do
      result =
        Result.from_json(%{"is_error" => true, "structured_output" => %{"name" => "Ada"}})

      assert {:error, %Error{kind: :structured_result_error}} =
               Structured.decode(ExtractPerson, result)
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
