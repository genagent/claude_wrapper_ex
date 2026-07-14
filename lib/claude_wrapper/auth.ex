defmodule ClaudeWrapper.Auth.Summary do
  @moduledoc """
  Snapshot of auth-relevant environment state.

  Returned by `ClaudeWrapper.Auth.detect/0` and
  `ClaudeWrapper.Auth.detect_from/1` so callers see both the resolved
  strategy and the raw signals that drove the decision.

  Mirrors the Rust `AuthSummary` struct from the `claude-wrapper` crate.
  """

  alias ClaudeWrapper.Auth

  @enforce_keys [
    :strategy,
    :has_anthropic_api_key,
    :has_auth_token,
    :has_oauth_token,
    :bedrock_enabled,
    :vertex_enabled
  ]
  defstruct [
    :strategy,
    :has_anthropic_api_key,
    :has_auth_token,
    :has_oauth_token,
    :bedrock_enabled,
    :vertex_enabled
  ]

  @type t :: %__MODULE__{
          strategy: Auth.strategy(),
          has_anthropic_api_key: boolean(),
          has_auth_token: boolean(),
          has_oauth_token: boolean(),
          bedrock_enabled: boolean(),
          vertex_enabled: boolean()
        }
end

defmodule ClaudeWrapper.Auth do
  @moduledoc """
  Detect which auth strategy the Claude Code CLI will use, and classify
  auth-related CLI failures.

  This is a standalone, env-only introspection module. It is **distinct**
  from `ClaudeWrapper.Commands.Auth`, which shells out to `claude auth`
  (login/logout/status/setup-token). Nothing here spawns a subprocess or
  reads the filesystem.

  ## Detection

  Claude Code resolves auth at invocation time by inspecting a few
  environment variables, falling back to credentials stored under
  `~/.claude/` when none are set. `detect/0` mirrors that precedence as a
  cheap, synchronous, env-only check so hosts can introspect the active
  mode before spawning a turn.

  It is **not** a liveness check -- a reported `:subscription` strategy
  only means "no env auth set"; the user might not have run `claude login`
  yet. Use `ClaudeWrapper.Commands.Auth.status/1` for that.

  Precedence (first match wins):

    1. `CLAUDE_CODE_USE_BEDROCK` truthy -> `:bedrock`
    2. `CLAUDE_CODE_USE_VERTEX` truthy -> `:vertex`
    3. `ANTHROPIC_API_KEY` non-empty -> `:api_key`
    4. `ANTHROPIC_AUTH_TOKEN` non-empty -> `:auth_token`
    5. `CLAUDE_CODE_OAUTH_TOKEN` non-empty -> `:oauth_token`
    6. Otherwise -> `:subscription`

  `ANTHROPIC_API_KEY` is ordered ahead of `ANTHROPIC_AUTH_TOKEN` because the
  direct-API key is the more common path; both are env-pinned header
  credentials, so their relative order only affects the reported label, not
  liveness.

  Cloud-provider strategies (Bedrock, Vertex) take precedence because
  they redirect ALL traffic regardless of API key presence.

  ## Failure classification

  `classify_failure/3` inspects a failed `claude` invocation and decides
  whether it looks auth-shaped. It returns the matching
  `t:auth_error_kind/0` atom, or `nil` when the failure is **not**
  auth-related. It is conservative on purpose: a false positive turns a
  legitimate non-auth failure into an "auth error" surprise, so the
  classifier prefers to miss an auth error rather than misclassify a
  non-auth one.

  Two recent fixes are preserved from the Rust reference:

    * A model-not-found / model-access failure (a bad `--model` id) must
      **not** be classified as auth, even when it carries a 403/404 HTTP
      status. It returns `nil`.
    * A `--bare` invocation with a missing API key prints
      "Not logged in" to stdout with empty stderr; that surfaces as
      `:not_authenticated`.

  ## Example

      summary = ClaudeWrapper.Auth.detect()
      summary.strategy
      #=> :subscription

      ClaudeWrapper.Auth.classify_failure(1, "", "HTTP 401 Unauthorized")
      #=> :invalid_credentials

      ClaudeWrapper.Auth.classify_failure(1, "no match found", "")
      #=> nil
  """

  alias ClaudeWrapper.Auth.Summary

  @typedoc """
  Active auth strategy, as inferred from the host environment.

    * `:bedrock` -- `CLAUDE_CODE_USE_BEDROCK` is truthy. Requests route to
      AWS Bedrock; AWS credentials are resolved separately by the SDK.
    * `:vertex` -- `CLAUDE_CODE_USE_VERTEX` is truthy. Requests route to
      Google Vertex; GCP credentials are resolved separately.
    * `:api_key` -- `ANTHROPIC_API_KEY` is set. Direct API access.
    * `:auth_token` -- `ANTHROPIC_AUTH_TOKEN` is set. A custom Bearer token
      sent as `Authorization: Bearer` (typically alongside `ANTHROPIC_BASE_URL`
      for a gateway / custom endpoint), distinct from `ANTHROPIC_API_KEY`,
      which is sent as `x-api-key`.
    * `:oauth_token` -- `CLAUDE_CODE_OAUTH_TOKEN` is set (typically from
      `claude setup-token`).
    * `:subscription` -- no auth env var set. The CLI looks for stored
      credentials under `~/.claude/`. May or may not actually be
      authenticated -- this reports "the env doesn't pin anything," not
      "you are logged in."

  See the module docs for precedence rules.
  """
  @type strategy :: :bedrock | :vertex | :api_key | :auth_token | :oauth_token | :subscription

  @typedoc """
  Best-effort classification of an auth-related CLI failure.

    * `:not_authenticated` -- no credentials at all. Fix: run
      `claude login` or set one of the auth env vars.
    * `:expired` -- stored credentials existed but are expired. Fix:
      re-run `claude login`.
    * `:invalid_credentials` -- credentials were presented but rejected
      (wrong/revoked key, stale token).
    * `:rate_limit` -- authenticated but rejected for rate limit / quota /
      billing reasons. Different remediation: wait, top up, or switch
      keys -- not "log in again."
    * `:provider_error` -- Bedrock or Vertex provider error (cloud creds
      missing or rejected). The fix lives in the cloud provider's auth.
    * `:other` -- looked auth-shaped (HTTP 401/403, the word "auth") but
      did not match a more specific pattern.
  """
  @type auth_error_kind ::
          :not_authenticated
          | :expired
          | :invalid_credentials
          | :rate_limit
          | :provider_error
          | :other

  @doc """
  Detect the active auth strategy from the current process environment.

  Cheap; no subprocess, no filesystem reads. Reads the real process env
  via `System.get_env/0`.
  """
  @spec detect() :: Summary.t()
  def detect, do: detect_from(System.get_env())

  @doc """
  Like `detect/0`, but reads from a caller-provided env map.

  Exposed for tests and for hosts that want to introspect a child
  environment they are about to spawn under. The map is keyed by env-var
  name, matching the shape of `System.get_env/0`.
  """
  @spec detect_from(%{optional(String.t()) => String.t()}) :: Summary.t()
  def detect_from(env) when is_map(env) do
    bedrock_enabled = truthy?(Map.get(env, "CLAUDE_CODE_USE_BEDROCK"))
    vertex_enabled = truthy?(Map.get(env, "CLAUDE_CODE_USE_VERTEX"))
    has_anthropic_api_key = set?(Map.get(env, "ANTHROPIC_API_KEY"))
    has_auth_token = set?(Map.get(env, "ANTHROPIC_AUTH_TOKEN"))
    has_oauth_token = set?(Map.get(env, "CLAUDE_CODE_OAUTH_TOKEN"))

    strategy =
      cond do
        bedrock_enabled -> :bedrock
        vertex_enabled -> :vertex
        has_anthropic_api_key -> :api_key
        has_auth_token -> :auth_token
        has_oauth_token -> :oauth_token
        true -> :subscription
      end

    %Summary{
      strategy: strategy,
      has_anthropic_api_key: has_anthropic_api_key,
      has_auth_token: has_auth_token,
      has_oauth_token: has_oauth_token,
      bedrock_enabled: bedrock_enabled,
      vertex_enabled: vertex_enabled
    }
  end

  @doc """
  Inspect a failed `claude` invocation and decide whether it looks
  auth-shaped.

  Returns the matching `t:auth_error_kind/0` atom only when the patterns
  are confident enough to risk relabeling, and `nil` otherwise.

  `exit_code` is accepted for parity with the Rust signature and future
  use; the current heuristics match only against the lowercased
  `stdout`/`stderr` text. The patterns are intentionally narrow:

    * model-not-found / model-access phrasing -> `nil` (a bad `--model`
      id is a typo, not a credential problem, even with a 403/404 status)
    * "not authenticated" / "not logged in" / "claude login" /
      "run /login" / "no credentials" / "no auth" -> `:not_authenticated`
    * "expired" / "session has expired" / "token expired" -> `:expired`
    * "invalid api key" / "invalid token" / "401" / "unauthorized" /
      "403" / "forbidden" -> `:invalid_credentials`
    * "rate limit" / "too many requests" / "429" / "quota" -> `:rate_limit`
    * "bedrock" or "vertex" alongside an auth signal -> `:provider_error`
    * a bare "auth" / "credential" mention in stderr -> `:other`
  """
  @spec classify_failure(integer(), String.t(), String.t()) :: auth_error_kind() | nil
  def classify_failure(exit_code, stdout, stderr)
      when is_integer(exit_code) and is_binary(stdout) and is_binary(stderr) do
    combined = String.downcase("#{stdout}\n#{stderr}")

    # Model-not-found / model-access failures bail before any auth pattern
    # can fire -- a bad `--model` id is a typo, not a credential problem,
    # even when it carries a 403/404 status.
    if mentions_model_problem?(combined) do
      nil
    else
      classify_auth(combined, String.downcase(stderr))
    end
  end

  defp classify_auth(combined, stderr_down) do
    cond do
      provider_error?(combined) -> :provider_error
      rate_limit?(combined) -> :rate_limit
      expired?(combined) -> :expired
      invalid_credentials?(combined) -> :invalid_credentials
      not_authenticated?(combined) -> :not_authenticated
      bare_auth_mention?(stderr_down) -> :other
      true -> nil
    end
  end

  # -- detection helpers ---------------------------------------------

  # Treat any non-empty, non-whitespace value as "set."
  defp set?(nil), do: false
  defp set?(value) when is_binary(value), do: String.trim(value) != ""

  # Truthy env var: any non-empty value that isn't a recognized falsy
  # literal (`0`, `false`, `no`, `off`, case-insensitive). Mirrors the
  # loose convention most CLI tools follow for `XYZ_USE_FOO` toggles.
  defp truthy?(nil), do: false

  defp truthy?(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> false
      "0" -> false
      "false" -> false
      "no" -> false
      "off" -> false
      _ -> true
    end
  end

  # -- classification helpers ----------------------------------------

  # Model-not-found / model-access failures are NOT auth errors, even
  # though they can carry a 403/404 HTTP status that the credential
  # checks would otherwise read as `:invalid_credentials`. A bad
  # `--model` id is a typo, not a credential problem; this guard must win
  # over every auth pattern below.
  defp mentions_model_problem?(combined) do
    contains_any?(combined, [
      "may not exist",
      "may not have access",
      "not_found_error",
      "issue with the selected model"
    ])
  end

  # Provider hits (Bedrock / Vertex) take precedence when the failure
  # mentions them alongside an auth signal -- the fix is different (cloud
  # creds, not `claude login`).
  defp provider_error?(combined) do
    mentions_provider? = contains_any?(combined, ["bedrock", "vertex"])

    mentions_auth_signal? =
      contains_any?(combined, [
        "auth",
        "credential",
        "401",
        "403",
        "forbidden",
        "unauthorized"
      ])

    mentions_provider? and mentions_auth_signal?
  end

  # NOTE (#208): needles are unanchored `String.contains?`, and the classifier
  # runs on a stderr_to_stdout blob, so bare tokens caught non-auth failures --
  # `"quota"` matched EDQUOT "disk quota exceeded", `"expired"` matched "SSL
  # certificate expired", bare `"401"`/`"403"`/`"429"` matched any output. Per the
  # module's "prefer to miss over misclassify" contract, the highest-risk needles
  # now require adjacent context; the broader word tokens (rate limit,
  # unauthorized, invalid api key, ...) stay as-is.
  defp rate_limit?(combined) do
    contains_any?(combined, [
      "rate limit",
      "too many requests",
      "http 429",
      "status 429",
      "usage limit",
      "usage quota"
    ])
  end

  defp expired?(combined) do
    contains_any?(combined, [
      "session has expired",
      "session expired",
      "token expired",
      "token has expired",
      "credentials expired",
      "api key expired"
    ])
  end

  defp invalid_credentials?(combined) do
    contains_any?(combined, [
      "invalid api key",
      "invalid token",
      "http 401",
      "status 401",
      "unauthorized",
      "http 403",
      "status 403",
      "forbidden"
    ])
  end

  defp not_authenticated?(combined) do
    contains_any?(combined, [
      "not authenticated",
      "not logged in",
      "claude login",
      "please run /login",
      "run /login",
      "no credentials",
      "no auth"
    ])
  end

  # Last-resort bucket: a bare "auth" or "credential" mention without
  # specifics. Conservative -- only fires on stderr (where these errors
  # typically land) so we don't catch e.g. `--allowed-tools auth_helper`.
  defp bare_auth_mention?(stderr_down) do
    contains_any?(stderr_down, ["auth", "credential"])
  end

  defp contains_any?(haystack, needles) do
    Enum.any?(needles, &String.contains?(haystack, &1))
  end
end
