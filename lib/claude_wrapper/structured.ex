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
  The returned result is decoded with `decode/2`.

  Error reasons, in addition to those from `decode/2`:

    * a `ClaudeWrapper.Error` -- `render/1` returned a non-prompt
      (`:invalid_render`), the prompt failed to render, or the CLI call
      failed (`:command_failed`, `:json`, `:timeout`, a rail stop, ...)
    * a `Jason` encode error -- `schema/0` was not JSON-encodable
  """
  @spec run(module(), term(), keyword()) :: {:ok, term(), Result.t()} | {:error, term()}
  def run(module, input, opts \\ []) when is_atom(module) and is_list(opts) do
    with {:ok, rendered} <- render_input(module, input),
         {:ok, schema_json} <- Jason.encode(module.schema()),
         {:ok, result} <-
           ClaudeWrapper.query(rendered, Keyword.put(opts, :json_schema, schema_json)) do
      decode(module, result)
    end
  end

  @doc """
  Decode the structured output of a result the caller already holds.

  Use this for a `ClaudeWrapper.DuplexSession.send/3` turn started with a
  `:json_schema`, or to re-decode an earlier `ClaudeWrapper.query/2`
  result. It never calls the CLI.

  `parser` is a `Structured` module (its optional `parse/1` is used; without
  one the object is returned unchanged) or a 1-arity function returning
  `{:ok, value}` or `{:error, reason}`.

  Returns `{:ok, parsed, result}` or `{:error, reason}`, checked in order:

    * `:structured_result_error` -- the result is a native error
      (`is_error: true`), even if it carries a `structured_output`. The
      native subtype, e.g. `"error_max_structured_output_retries"`, stays
      readable as `result.extra["subtype"]`. `:reason` is the result.
    * `:no_structured_output` -- `structured_output` is absent or null, i.e.
      no `--json-schema` took effect. `:reason` is the result.
    * `:invalid_structured_output` -- `structured_output` is present but is
      neither a JSON object nor an array. `:reason` is the result.
    * whatever the parser returned as `{:error, reason}` -- the output did
      not have the expected domain shape
    * `:invalid_parse_result` -- the parser returned something other than
      `{:ok, _}` or `{:error, _}`. `:reason` is the returned value.

  Native `--json-schema` validation happens inside the CLI; this function
  does not re-validate the object against the schema. The parser is the
  caller-side check.
  """
  @spec decode(module() | (term() -> {:ok, term()} | {:error, term()}), Result.t()) ::
          {:ok, term(), Result.t()} | {:error, term()}
  def decode(parser, %Result{} = result) when is_atom(parser) or is_function(parser, 1) do
    with {:ok, output} <- extract_output(result),
         {:ok, parsed} <- parse_output(parser, output) do
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

  defp extract_output(%Result{is_error: true} = result),
    do: {:error, Error.new(:structured_result_error, reason: result)}

  defp extract_output(%Result{extra: extra} = result) do
    case Map.get(extra, "structured_output") do
      nil -> {:error, Error.new(:no_structured_output, reason: result)}
      output when is_map(output) or is_list(output) -> {:ok, output}
      _other -> {:error, Error.new(:invalid_structured_output, reason: result)}
    end
  end

  defp parse_output(parser, output) do
    case apply_parser(parser, output) do
      {:ok, _parsed} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, Error.new(:invalid_parse_result, reason: other)}
    end
  end

  defp apply_parser(parser, output) when is_function(parser, 1), do: parser.(output)

  # decode/2 may be the first reference to the module, so load it before
  # checking for the optional callback.
  defp apply_parser(module, output) do
    if Code.ensure_loaded?(module) and function_exported?(module, :parse, 1) do
      module.parse(output)
    else
      {:ok, output}
    end
  end
end
