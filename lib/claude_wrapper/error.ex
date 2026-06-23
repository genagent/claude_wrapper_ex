defmodule ClaudeWrapper.Error do
  @moduledoc """
  Canonical error type for ClaudeWrapper.

  Every operational failure in this library is returned as
  `{:error, %ClaudeWrapper.Error{}}` and can also be raised (it is a
  proper exception). Branch on the `:kind` atom for the failure
  category; the `:reason` field plus the dedicated `:exit_code` /
  `:stdout` / `:stderr` fields carry the details.

      case ClaudeWrapper.query("hi") do
        {:ok, result} -> result
        {:error, %ClaudeWrapper.Error{kind: :max_turns_exceeded}} -> :hit_limit
        {:error, %ClaudeWrapper.Error{kind: :command_failed, exit_code: code}} -> code
      end

  The variant set mirrors the Rust `claude-wrapper` `Error` enum.

  ## Kinds

    * `:binary_not_found` -- the `claude` binary could not be launched
    * `:command_failed` -- the CLI exited non-zero (`:exit_code`,
      `:stdout`, `:stderr`)
    * `:io` -- an OS/IO error launching or talking to the CLI
      (`:reason`)
    * `:timeout` -- the call exceeded its timeout (`:reason` is the
      timeout in ms)
    * `:json` -- the CLI output could not be decoded as JSON
      (`:reason`, optional `:stdout`)
    * `:max_turns_exceeded` -- the CLI stopped at its `--max-turns`
      limit
    * `:version_mismatch` -- the CLI is older than a required minimum
      (`:reason` is `%{found:, minimum:}`)
    * `:invalid_version` -- a version string could not be parsed
      (`:reason` is the original string)
    * `:budget_exceeded` -- a client-side budget ceiling was hit
      (`:reason` is `%{total_usd:, max_usd:}`)
    * `:dangerous_not_allowed` -- a bypass query was attempted without
      the opt-in env var (`:reason` is the env var name)
    * `:duplex_closed` -- the duplex session port was already closed
    * `:turn_in_flight` -- a turn is already running on the session
    * `:duplex_control_failed` -- an interrupt/permission control
      message failed (`:reason`)
    * `:terminated` -- the session terminated while a turn was pending
    * `:cannot_defer_again` -- a permission decision was deferred twice
    * `:no_session` -- a REPL helper was used with no active session
    * `:not_found` -- a requested resource does not exist (`:reason`
      identifies it)
    * `:already_exists` -- a create-new target already exists
      (`:reason`)
    * `:invalid_stem` -- an invalid file stem / identifier (`:reason`)
    * `:no_home` -- the user home directory could not be determined
    * `:invalid_settings_json` -- a settings file is not valid JSON
      (`:reason` is `%{path:, error:}`)
    * `:settings_read_error` -- a settings file could not be read
      (`:reason` is `%{path:, error:}`)
    * `:not_a_git_repo` -- a path is not inside a git repo (`:reason`
      is the path)
    * `:git_failed` -- a `git` invocation failed (`:reason`)
    * `:git_unavailable` -- the `git` binary is not available
      (`:reason`)
    * `:invalid_tool_pattern` -- a tool pattern failed validation
      (`:reason` is the specific problem)
    * `:auth` -- an authentication failure, classified into `:reason`
      (see `t:ClaudeWrapper.Auth.auth_error_kind/0`)
  """

  @type kind ::
          :binary_not_found
          | :command_failed
          | :io
          | :timeout
          | :json
          | :max_turns_exceeded
          | :version_mismatch
          | :invalid_version
          | :budget_exceeded
          | :dangerous_not_allowed
          | :duplex_closed
          | :turn_in_flight
          | :duplex_control_failed
          | :terminated
          | :cannot_defer_again
          | :no_session
          | :not_found
          | :already_exists
          | :invalid_stem
          | :no_home
          | :invalid_settings_json
          | :settings_read_error
          | :not_a_git_repo
          | :git_failed
          | :git_unavailable
          | :invalid_tool_pattern
          | :auth
          | :invalid_render
          | :no_structured_output

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t() | nil,
          reason: term(),
          exit_code: integer() | nil,
          stdout: String.t() | nil,
          stderr: String.t() | nil
        }

  defexception [:kind, :message, :reason, :exit_code, :stdout, :stderr]

  @impl true
  def exception(opts) when is_list(opts) do
    %__MODULE__{
      kind: Keyword.fetch!(opts, :kind),
      message: opts[:message],
      reason: opts[:reason],
      exit_code: opts[:exit_code],
      stdout: opts[:stdout],
      stderr: opts[:stderr]
    }
  end

  @impl true
  def message(%__MODULE__{message: msg}) when is_binary(msg), do: msg
  def message(%__MODULE__{} = error), do: default_message(error)

  @doc """
  Build an error of `kind`, with optional `:message`, `:reason`,
  `:exit_code`, `:stdout`, `:stderr`.
  """
  @spec new(kind(), keyword()) :: t()
  def new(kind, opts \\ []) when is_atom(kind), do: exception([{:kind, kind} | opts])

  @doc "A `:command_failed` error from a non-zero CLI exit."
  @spec command_failed(integer(), String.t(), String.t() | nil) :: t()
  def command_failed(exit_code, stdout, stderr \\ nil) do
    %__MODULE__{kind: :command_failed, exit_code: exit_code, stdout: stdout, stderr: stderr}
  end

  @doc "A `:timeout` error (`ms` is the elapsed timeout)."
  @spec timeout(non_neg_integer()) :: t()
  def timeout(ms), do: %__MODULE__{kind: :timeout, reason: ms}

  @doc "A `:json` decode error, optionally carrying the raw `stdout`."
  @spec json(term(), String.t() | nil) :: t()
  def json(reason, stdout \\ nil), do: %__MODULE__{kind: :json, reason: reason, stdout: stdout}

  @doc "An `:io` error wrapping an underlying reason."
  @spec io(term()) :: t()
  def io(reason), do: %__MODULE__{kind: :io, reason: reason}

  # --- default messages ---------------------------------------------

  defp default_message(%{kind: :binary_not_found, reason: bin}),
    do: "claude binary not found: #{inspect(bin)}"

  defp default_message(%{kind: :command_failed, exit_code: code}),
    do: "claude exited with status #{code}"

  defp default_message(%{kind: :io, reason: reason}),
    do: "i/o error running claude: #{inspect(reason)}"

  defp default_message(%{kind: :timeout, reason: ms}),
    do: "claude timed out after #{ms}ms"

  defp default_message(%{kind: :json}),
    do: "could not decode claude JSON output"

  defp default_message(%{kind: :max_turns_exceeded}),
    do: "claude reached its maximum number of turns"

  defp default_message(%{kind: :version_mismatch, reason: %{found: found, minimum: min}}),
    do: "claude #{found} is older than the required minimum #{min}"

  defp default_message(%{kind: :invalid_version, reason: original}),
    do: "invalid version string: #{inspect(original)}"

  defp default_message(%{kind: :budget_exceeded, reason: %{total_usd: total, max_usd: max}}),
    do: "budget exceeded: $#{total} spent of $#{max} ceiling"

  defp default_message(%{kind: :dangerous_not_allowed, reason: env}),
    do: "dangerous operations require #{env}=1"

  defp default_message(%{kind: :duplex_closed}), do: "the duplex session is closed"
  defp default_message(%{kind: :turn_in_flight}), do: "a turn is already in flight"

  defp default_message(%{kind: :duplex_control_failed, reason: reason}),
    do: "duplex control message failed: #{inspect(reason)}"

  defp default_message(%{kind: :terminated}), do: "the session terminated with a turn pending"

  defp default_message(%{kind: :cannot_defer_again}),
    do: "a deferred permission cannot defer again"

  defp default_message(%{kind: :no_session}), do: "no active session"

  defp default_message(%{kind: :not_found, reason: reason}) when not is_nil(reason),
    do: "not found: #{inspect(reason)}"

  defp default_message(%{kind: :not_found}), do: "not found"
  defp default_message(%{kind: :already_exists, reason: r}), do: "already exists: #{inspect(r)}"
  defp default_message(%{kind: :invalid_stem, reason: r}), do: "invalid identifier: #{inspect(r)}"
  defp default_message(%{kind: :no_home}), do: "could not determine the user home directory"

  defp default_message(%{kind: :invalid_settings_json, reason: %{path: path}}),
    do: "settings file is not valid JSON: #{path}"

  defp default_message(%{kind: :settings_read_error, reason: %{path: path}}),
    do: "could not read settings file: #{path}"

  defp default_message(%{kind: :not_a_git_repo, reason: path}),
    do: "not a git repository: #{path}"

  defp default_message(%{kind: :git_failed, reason: reason}),
    do: "git failed: #{inspect(reason)}"

  defp default_message(%{kind: :git_unavailable}), do: "the git binary is not available"

  defp default_message(%{kind: :invalid_tool_pattern, reason: reason}),
    do: "invalid tool pattern: #{inspect(reason)}"

  defp default_message(%{kind: :auth, reason: reason}),
    do: "authentication error: #{inspect(reason)}"

  defp default_message(%{kind: :invalid_render, reason: value}),
    do: "Structured render/1 returned #{inspect(value)}; expected a Prompt or a string"

  defp default_message(%{kind: :no_structured_output}),
    do: "the result carried no structured_output (no JSON schema took effect)"

  defp default_message(%{kind: kind}), do: "claude_wrapper error: #{kind}"
end
