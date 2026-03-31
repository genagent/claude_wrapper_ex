defmodule ClaudeWrapper.StreamEvent do
  @moduledoc """
  A single event from the Claude CLI's NDJSON streaming output.

  When using `--output-format stream-json`, the CLI emits one JSON object
  per line. Each event has a type and associated data.

  ## Event types

  Common event types include:
  - `"system"` — system initialization
  - `"assistant"` — assistant message content
  - `"tool_use"` — tool invocation
  - `"tool_result"` — tool execution result
  - `"result"` — final result with cost/session info
  - `"error"` — error during execution
  """

  @type t :: %__MODULE__{
          type: String.t() | nil,
          data: map(),
          raw: String.t()
        }

  defstruct [:type, :raw, data: %{}]

  @doc """
  Parse a single NDJSON line into a stream event.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
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
        {:error, :not_an_object}

      {:error, reason} ->
        {:error, {:json_decode, reason}}
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
end
