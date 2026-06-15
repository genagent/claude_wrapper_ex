defmodule ClaudeWrapper.StreamEvent do
  @moduledoc """
  A single event from the Claude CLI's NDJSON streaming output.

  When using `--output-format stream-json`, the CLI emits one JSON object
  per line. Each event has a type and associated data.

  ## Event types

  Common event types include:
  - `"system"` -- system initialization
  - `"assistant"` -- assistant message content
  - `"tool_use"` -- tool invocation
  - `"tool_result"` -- tool execution result
  - `"result"` -- final result with cost/session info
  - `"error"` -- error during execution
  """

  @type t :: %__MODULE__{
          type: String.t() | nil,
          data: map(),
          raw: String.t() | nil
        }

  @typedoc """
  The kind of content block reported by a `:block_start` partial message.

  Mirrors the `content_block.type` field from the Anthropic streaming API.
  Block kinds not modelled here surface as `{:other, raw_type}` -- callers
  can still recover the type name from the carried string.
  """
  @type block_type ::
          :text
          | :thinking
          | {:tool_use, id :: String.t(), name :: String.t()}
          | {:other, String.t()}

  @typedoc """
  The incremental payload carried by a `:block_delta` partial message.

  Mirrors the `delta.type` field from the Anthropic streaming API. Less
  common delta kinds (signature, citations, ...) collapse to `:other`;
  callers that need them can fall back to the struct's `:data` field.
  """
  @type block_delta ::
          {:text, String.t()}
          | {:thinking, String.t()}
          | {:input_json, String.t()}
          | :other

  @typedoc """
  A decoded partial-message event from a streaming `claude` call.

  Returned by `partial_message/1`. The three variants correspond to the
  Anthropic streaming content-block lifecycle: a block starts, gets one
  or more deltas, then stops.
  """
  @type partial_message ::
          {:block_start, index :: non_neg_integer(), block_type()}
          | {:block_delta, index :: non_neg_integer(), block_delta()}
          | {:block_stop, index :: non_neg_integer()}

  defstruct [:type, :raw, data: %{}]

  @doc """
  Parse a single NDJSON line into a stream event.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, ClaudeWrapper.Error.t()}
  def parse(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, data} when is_map(data) ->
        {:ok,
         %__MODULE__{
           type: data["type"],
           data: data,
           raw: line
         }}

      {:ok, _other} ->
        {:error, ClaudeWrapper.Error.json(:not_an_object)}

      {:error, reason} ->
        {:error, ClaudeWrapper.Error.json(reason)}
    end
  end

  @doc """
  Whether this is the final result event.
  """
  @spec result?(t()) :: boolean()
  def result?(%__MODULE__{type: "result"}), do: true
  def result?(%__MODULE__{}), do: false

  @doc """
  Extract the result text, if this is a result event.
  """
  @spec result_text(t()) :: String.t() | nil
  def result_text(%__MODULE__{type: "result", data: data}), do: data["result"]
  def result_text(%__MODULE__{}), do: nil

  @doc """
  Extract the session ID, if present.
  """
  @spec session_id(t()) :: String.t() | nil
  def session_id(%__MODULE__{data: data}), do: data["session_id"]

  @doc """
  Extract cost in USD, if present.
  """
  @spec cost_usd(t()) :: float() | nil
  def cost_usd(%__MODULE__{data: data}), do: data["cost_usd"]

  @doc """
  Decode a partial-message event into a typed, tagged view.

  Returns the tagged tuple when the event is one of the content-block
  lifecycle events surfaced with `--include-partial-messages` -- start,
  delta, or stop. Returns `nil` for any other event (system, assistant,
  result, message-level stream events, etc.).

  The CLI wraps each raw streaming event as
  `%{"type" => "stream_event", "event" => %{...}}`; this accessor unwraps
  that envelope. A raw (unwrapped) content-block event is also accepted.
  Unknown block types and unknown delta types fall through to
  `{:other, type}` / `:other` rather than returning `nil`, so future
  content-block kinds remain accessible (just untyped).

  ## Examples

      iex> {:ok, event} =
      ...>   ClaudeWrapper.StreamEvent.parse(
      ...>     ~s({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}})
      ...>   )
      iex> ClaudeWrapper.StreamEvent.partial_message(event)
      {:block_delta, 0, {:text, "Hi"}}

      iex> {:ok, event} = ClaudeWrapper.StreamEvent.parse(~s({"type":"result","result":"done"}))
      iex> ClaudeWrapper.StreamEvent.partial_message(event)
      nil
  """
  @spec partial_message(t()) :: partial_message() | nil
  def partial_message(%__MODULE__{type: "stream_event", data: %{"event" => event}})
      when is_map(event) do
    decode_partial(event)
  end

  def partial_message(%__MODULE__{data: data}), do: decode_partial(data)

  defp decode_partial(%{"type" => "content_block_start", "index" => index} = event)
       when is_integer(index) and index >= 0 do
    {:block_start, index, parse_block_type(Map.get(event, "content_block"))}
  end

  defp decode_partial(%{"type" => "content_block_delta", "index" => index} = event)
       when is_integer(index) and index >= 0 do
    {:block_delta, index, parse_block_delta(Map.get(event, "delta"))}
  end

  defp decode_partial(%{"type" => "content_block_stop", "index" => index})
       when is_integer(index) and index >= 0 do
    {:block_stop, index}
  end

  defp decode_partial(_other), do: nil

  defp parse_block_type(%{"type" => "text"}), do: :text
  defp parse_block_type(%{"type" => "thinking"}), do: :thinking

  defp parse_block_type(%{"type" => "tool_use"} = block) do
    {:tool_use, to_string(Map.get(block, "id", "")), to_string(Map.get(block, "name", ""))}
  end

  defp parse_block_type(%{"type" => type}), do: {:other, type}
  defp parse_block_type(_), do: {:other, ""}

  defp parse_block_delta(%{"type" => "text_delta", "text" => text}) when is_binary(text),
    do: {:text, text}

  defp parse_block_delta(%{"type" => "thinking_delta", "thinking" => text})
       when is_binary(text),
       do: {:thinking, text}

  defp parse_block_delta(%{"type" => "input_json_delta", "partial_json" => json})
       when is_binary(json),
       do: {:input_json, json}

  defp parse_block_delta(_), do: :other
end
