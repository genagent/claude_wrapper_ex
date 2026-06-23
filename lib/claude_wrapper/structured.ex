defmodule ClaudeWrapper.Structured do
  @moduledoc """
  Run a Claude call as a typed function.

  A `Structured` task turns **structured input** into a rendered prompt,
  constrains the model's output to a **JSON Schema**, and parses the
  validated object into a **domain value** -- returning the raw
  `t:ClaudeWrapper.Result.t/0` alongside as an audit log. The model call is
  the only stochastic step; prompt construction, output shape, and parsing
  are deterministic and typed -- a deterministic envelope around a
  stochastic core.

  A task module implements:

    * `render/1` -- input -> a `t:ClaudeWrapper.Prompt.t/0` or a string
    * `schema/0` -- the JSON Schema the output must conform to (claude's
      `--json-schema`); the validated object arrives as the result's
      `structured_output`
    * `parse/1` -- *optional*; map the validated object into a domain
      value. Defaults to returning the object unchanged.

  `run/3` wires them together.

  ## Example

      defmodule ExtractName do
        @behaviour ClaudeWrapper.Structured

        @impl true
        def render(text), do: "Extract the person's name from: " <> text

        @impl true
        def schema do
          %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}},
            "required" => ["name"]
          }
        end
      end

      {:ok, %{"name" => name}, %ClaudeWrapper.Result{}} =
        ClaudeWrapper.Structured.run(ExtractName, "Hi, I'm Ada Lovelace.")

  ## Parsing into a domain value

  An optional `parse/1` maps the validated object into whatever shape the
  caller wants -- a struct, an Ecto schema, a normalized tuple. The model
  still only returns the schema-validated object; `parse/1` is the
  deterministic last step.

      defmodule ExtractPerson do
        @behaviour ClaudeWrapper.Structured

        @impl true
        def render(text), do: "Extract the person's full name from: " <> text

        @impl true
        def schema, do: ExtractName.schema()

        @impl true
        def parse(%{"name" => name}), do: {:ok, %Person{name: name}}
        def parse(other), do: {:error, {:unexpected_shape, other}}
      end

      {:ok, %Person{name: "Ada Lovelace"}, %ClaudeWrapper.Result{}} =
        ClaudeWrapper.Structured.run(ExtractPerson, "Hi, I'm Ada Lovelace.")

  ## Reasoning room

  A hard schema gives the model no space to think before answering. If a
  task needs reasoning, add a field for it to the schema (e.g. a
  `"reasoning"` string beside the `"answer"` object) rather than dropping
  the schema -- you keep a guaranteed-parseable object *and* thinking room
  in one deterministic call.
  """

  alias ClaudeWrapper.{Error, Prompt, Result}

  @doc "Turn the task input into a prompt (a `Prompt` struct or a string)."
  @callback render(input :: term()) :: Prompt.t() | String.t()

  @doc "The JSON Schema the model output must conform to."
  @callback schema() :: map()

  @doc """
  Map the schema-validated object into a domain value. Optional; the
  default returns the object unchanged.

      def parse(%{"name" => name}), do: {:ok, %Person{name: name}}
  """
  @callback parse(structured_output :: map() | list()) :: {:ok, term()} | {:error, term()}

  @optional_callbacks parse: 1

  @doc """
  Run `module` over `input`.

  Returns `{:ok, parsed, result}` -- the parsed domain value plus the raw
  `t:ClaudeWrapper.Result.t/0` (the audit log) -- or `{:error, reason}`.

  `opts` are forwarded to `ClaudeWrapper.query/2` (e.g. `:model`,
  `:working_dir`, `:timeout`); `:json_schema` is set from `schema/0`.

  Error reasons:

    * a `ClaudeWrapper.Error` -- `render/1` returned a non-prompt
      (`:invalid_render`), the prompt failed to render, the CLI call
      failed, or the result carried no `structured_output`
      (`:no_structured_output`)
    * a `Jason` encode error -- `schema/0` was not JSON-encodable
    * whatever `parse/1` returned on `{:error, _}`
  """
  @spec run(module(), term(), keyword()) :: {:ok, term(), Result.t()} | {:error, term()}
  def run(module, input, opts \\ []) when is_atom(module) and is_list(opts) do
    with {:ok, rendered} <- render_input(module, input),
         {:ok, schema_json} <- Jason.encode(module.schema()),
         {:ok, result} <-
           ClaudeWrapper.query(rendered, Keyword.put(opts, :json_schema, schema_json)),
         {:ok, output} <- extract_output(result),
         {:ok, parsed} <- parse_output(module, output) do
      {:ok, parsed, result}
    end
  end

  defp render_input(module, input) do
    case module.render(input) do
      %Prompt{} = prompt -> Prompt.render(prompt)
      text when is_binary(text) -> {:ok, text}
      other -> {:error, Error.new(:invalid_render, reason: other)}
    end
  end

  # Read the schema-validated object via the typed accessor (#142).
  defp extract_output(%Result{} = result) do
    case Result.structured_output(result) do
      nil -> {:error, Error.new(:no_structured_output, reason: result)}
      output -> {:ok, output}
    end
  end

  defp parse_output(module, output) do
    if function_exported?(module, :parse, 1) do
      module.parse(output)
    else
      {:ok, output}
    end
  end
end
