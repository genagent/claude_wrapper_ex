defmodule ClaudeWrapper.AuthTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Auth
  alias ClaudeWrapper.Auth.Summary

  describe "detect/0" do
    test "reads the real process env and returns a summary" do
      assert %Summary{strategy: strategy} = Auth.detect()
      assert strategy in [:bedrock, :vertex, :api_key, :auth_token, :oauth_token, :subscription]
    end
  end

  describe "detect_from/1 -- strategies and precedence" do
    test "empty env is subscription with all flags false" do
      s = Auth.detect_from(%{})

      assert s.strategy == :subscription
      refute s.has_anthropic_api_key
      refute s.has_auth_token
      refute s.has_oauth_token
      refute s.bedrock_enabled
      refute s.vertex_enabled
    end

    test "ANTHROPIC_AUTH_TOKEN alone picks :auth_token" do
      s = Auth.detect_from(%{"ANTHROPIC_AUTH_TOKEN" => "sk-ant-..."})

      assert s.strategy == :auth_token
      assert s.has_auth_token
      refute s.has_anthropic_api_key
    end

    test "ANTHROPIC_API_KEY takes precedence over ANTHROPIC_AUTH_TOKEN" do
      s = Auth.detect_from(%{"ANTHROPIC_API_KEY" => "sk-abc", "ANTHROPIC_AUTH_TOKEN" => "tok"})

      assert s.strategy == :api_key
      assert s.has_anthropic_api_key
      assert s.has_auth_token
    end

    test "ANTHROPIC_AUTH_TOKEN takes precedence over CLAUDE_CODE_OAUTH_TOKEN" do
      s =
        Auth.detect_from(%{"ANTHROPIC_AUTH_TOKEN" => "tok", "CLAUDE_CODE_OAUTH_TOKEN" => "oauth"})

      assert s.strategy == :auth_token
    end

    test "api key takes precedence over oauth token" do
      s =
        Auth.detect_from(%{
          "ANTHROPIC_API_KEY" => "sk-abc",
          "CLAUDE_CODE_OAUTH_TOKEN" => "tok-xyz"
        })

      assert s.strategy == :api_key
      assert s.has_anthropic_api_key
      assert s.has_oauth_token
    end

    test "oauth token alone picks oauth_token" do
      s = Auth.detect_from(%{"CLAUDE_CODE_OAUTH_TOKEN" => "tok-xyz"})

      assert s.strategy == :oauth_token
      refute s.has_anthropic_api_key
      assert s.has_oauth_token
    end

    test "bedrock overrides api key" do
      s =
        Auth.detect_from(%{
          "CLAUDE_CODE_USE_BEDROCK" => "1",
          "ANTHROPIC_API_KEY" => "sk-abc"
        })

      assert s.strategy == :bedrock
      assert s.bedrock_enabled
      assert s.has_anthropic_api_key
    end

    test "vertex overrides oauth token" do
      s =
        Auth.detect_from(%{
          "CLAUDE_CODE_USE_VERTEX" => "true",
          "CLAUDE_CODE_OAUTH_TOKEN" => "tok-xyz"
        })

      assert s.strategy == :vertex
      assert s.vertex_enabled
    end

    test "bedrock takes precedence over vertex when both set" do
      s =
        Auth.detect_from(%{
          "CLAUDE_CODE_USE_BEDROCK" => "1",
          "CLAUDE_CODE_USE_VERTEX" => "1"
        })

      assert s.strategy == :bedrock
      assert s.bedrock_enabled
      assert s.vertex_enabled
    end

    test "empty / whitespace string does not count as set" do
      s =
        Auth.detect_from(%{
          "ANTHROPIC_API_KEY" => "",
          "CLAUDE_CODE_OAUTH_TOKEN" => "   "
        })

      assert s.strategy == :subscription
      refute s.has_anthropic_api_key
      refute s.has_oauth_token
    end

    test "explicit falsy disables provider flags" do
      s =
        Auth.detect_from(%{
          "CLAUDE_CODE_USE_BEDROCK" => "0",
          "CLAUDE_CODE_USE_VERTEX" => "false",
          "ANTHROPIC_API_KEY" => "sk-abc"
        })

      assert s.strategy == :api_key
      refute s.bedrock_enabled
      refute s.vertex_enabled
    end

    test "truthy values are recognized" do
      for v <- ["1", "true", "TRUE", "yes", "on", "anything"] do
        s = Auth.detect_from(%{"CLAUDE_CODE_USE_BEDROCK" => v})
        assert s.strategy == :bedrock, "value #{inspect(v)}"
        assert s.bedrock_enabled, "value #{inspect(v)}"
      end
    end

    test "falsy values are recognized" do
      for v <- ["0", "false", "FALSE", "no", "off"] do
        s = Auth.detect_from(%{"CLAUDE_CODE_USE_BEDROCK" => v})
        assert s.strategy == :subscription, "value #{inspect(v)}"
        refute s.bedrock_enabled, "value #{inspect(v)}"
      end
    end
  end

  describe "classify_failure/3 -- negative cases" do
    test "returns nil for an unrelated failure" do
      assert Auth.classify_failure(1, "no match found", "") == nil
      assert Auth.classify_failure(2, "", "syntax error near unexpected token") == nil
    end

    test "model-not-found is not auth (a model typo must not halt fleets)" do
      # Mirrors real `claude --output-format json` output for a bad --model.
      bad_model =
        ~s|{"type":"result","is_error":true,"api_error_status":404,| <>
          ~s|"result":"There's an issue with the selected model (totally-not-a-model-xyz). | <>
          ~s|It may not exist or you may not have access to it. Run --model to pick a different model."}|

      assert Auth.classify_failure(1, bad_model, "") == nil
    end

    test "model-access 403/404 wins over invalid_credentials" do
      assert Auth.classify_failure(
               1,
               "",
               "API Error: 403 Forbidden permission_error: you may not have access to model claude-x"
             ) == nil

      assert Auth.classify_failure(
               1,
               "",
               "404 not_found_error: model claude-x does not exist"
             ) == nil
    end

    test "bare auth mention in stdout only is not classified" do
      assert Auth.classify_failure(0, "auth_helper enabled, all clear", "") == nil
    end
  end

  describe "classify_failure/3 -- positive cases" do
    test "not authenticated from stderr hint" do
      assert Auth.classify_failure(
               1,
               "",
               "Not authenticated. Run `claude login` to sign in."
             ) == :not_authenticated

      assert Auth.classify_failure(1, "", "no credentials configured") == :not_authenticated
    end

    test "--bare missing key (stdout-only, empty stderr) -> not_authenticated" do
      assert Auth.classify_failure(1, "Not logged in · Please run /login", "") ==
               :not_authenticated
    end

    test "expired session" do
      assert Auth.classify_failure(
               1,
               "",
               "Your session has expired. Please log in again."
             ) == :expired

      assert Auth.classify_failure(1, "", "token expired at 2025-01-01T00:00:00Z") == :expired
    end

    test "invalid api key / 401 / 403" do
      assert Auth.classify_failure(1, "", "Invalid API key. Check ANTHROPIC_API_KEY.") ==
               :invalid_credentials

      assert Auth.classify_failure(1, "", "HTTP 401 Unauthorized") == :invalid_credentials
      assert Auth.classify_failure(1, "", "403 Forbidden") == :invalid_credentials
    end

    test "rate limit takes precedence over invalid credentials wording" do
      assert Auth.classify_failure(1, "", "Rate limit exceeded. Please wait.") == :rate_limit
      assert Auth.classify_failure(1, "", "HTTP 429 Too Many Requests") == :rate_limit
      assert Auth.classify_failure(1, "", "usage quota exceeded for this account") == :rate_limit
    end

    test "bare disk-quota / SSL-expired / stray HTTP codes no longer misclassify as auth (#208)" do
      # EDQUOT "disk quota" must not read as a rate limit (only "usage quota" does).
      refute Auth.classify_failure(1, "", "write failed: disk quota exceeded") == :rate_limit
      # "SSL certificate expired" must not read as an expired credential.
      refute Auth.classify_failure(1, "", "SSL certificate has expired") == :expired
      # A bare 401/403 in arbitrary output must not read as invalid credentials.
      refute Auth.classify_failure(1, "", "downstream returned 403 for /assets/401.png") ==
               :invalid_credentials
    end

    test "provider error when bedrock/vertex appears alongside an auth signal" do
      assert Auth.classify_failure(
               1,
               "",
               "Bedrock auth failed: AWS credentials not found in chain"
             ) == :provider_error

      assert Auth.classify_failure(
               1,
               "",
               "Vertex unauthorized -- check GOOGLE_APPLICATION_CREDENTIALS"
             ) == :provider_error
    end

    test "falls back to :other for a bare auth mention in stderr" do
      assert Auth.classify_failure(1, "", "auth subsystem returned an unexpected error") ==
               :other
    end

    test "specific patterns match in stdout too" do
      assert Auth.classify_failure(1, "Invalid API key", "") == :invalid_credentials
    end
  end
end
