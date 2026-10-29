defmodule ClaudeWrapper.ApiErrorTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, DuplexSession, Error, Query, Result, Retry}

  @fake Path.expand("../fixtures/fake_claude", __DIR__)

  defp config(scenario, env \\ []),
    do: Config.new(binary: @fake, env: [{"FAKE_CLAUDE_SCENARIO", scenario} | env])

  defp execute(scenario, env \\ []), do: Query.execute(Query.new("ping"), config(scenario, env))

  describe "Query.execute/2" do
    test "HTTP API errors become :api_error with a category" do
      for {scenario, status, category} <- [
            {"api_429", 429, :rate_limit},
            {"api_529", 529, :overloaded},
            {"api_503", 503, :server_error},
            {"api_403", 403, :client_error}
          ] do
        assert {:error,
                %Error{
                  kind: :api_error,
                  exit_code: 1,
                  reason: %{
                    status: ^status,
                    category: ^category,
                    num_turns: 1,
                    session_id: "fake-session",
                    message: "API Error: synthetic " <> _
                  }
                }} = execute(scenario)
      end
    end

    test "a result without an HTTP status is a :connection error" do
      assert {:error, %Error{kind: :api_error, reason: %{status: nil, category: :connection}}} =
               execute("api_connection")
    end

    test "a 401 is :auth with :invalid_credentials" do
      assert {:error, %Error{kind: :auth, reason: :invalid_credentials, exit_code: 1}} =
               execute("api_401")
    end

    test "rail stops and successful results are unchanged" do
      assert {:ok, %Result{is_error: false}} = execute("object")
      assert {:error, %Error{kind: :max_turns_exceeded}} = execute("max_turns")
    end
  end

  @tag :forcola_evidence
  test "observed execute/3 classifies the same way" do
    config = %{config("api_429") | runner: ClaudeWrapper.Runner.Forcola}

    assert {:error, %Error{kind: :api_error, reason: %{status: 429, category: :rate_limit}}} =
             Query.execute(Query.new("ping"), config, session_observer: {self(), make_ref()})
  end

  test "DuplexSession.send/3 returns the typed error and still broadcasts the result" do
    {:ok, session, stub} = ClaudeWrapper.Test.start_session()
    :ok = DuplexSession.subscribe(session)

    ClaudeWrapper.Test.stub(stub, [
      ClaudeWrapper.Test.result(
        is_error: true,
        terminal_reason: "api_error",
        api_error_status: 529,
        num_turns: 1,
        result: "API Error: overloaded"
      )
    ])

    assert {:error, %Error{kind: :api_error, reason: %{status: 529, category: :overloaded}}} =
             DuplexSession.send(session, "hi")

    assert_receive {:claude, {:result, %Result{is_error: true}}}
  end

  describe "Retry" do
    test "retries a transient API error from a turn that ran no tools" do
      calls = Path.join(System.tmp_dir!(), "api-retry-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(calls) end)

      assert {:error, %Error{kind: :api_error}} =
               Retry.execute(Query.new("ping"), config("api_429", [{"FAKE_CLAUDE_CALLS", calls}]),
                 max_retries: 2,
                 base_delay_ms: 1,
                 jitter: false
               )

      assert calls |> File.read!() |> String.split("\n", trim: true) |> length() == 3
    end

    test "does not retry after a tool round trip or for client errors" do
      refute Retry.default_retry_on(
               {:error, Error.new(:api_error, reason: %{category: :rate_limit, num_turns: 2})}
             )

      refute Retry.default_retry_on(
               {:error, Error.new(:api_error, reason: %{category: :client_error, num_turns: 1})}
             )

      for category <- [:rate_limit, :overloaded, :server_error, :connection] do
        assert Retry.default_retry_on(
                 {:error, Error.new(:api_error, reason: %{category: category, num_turns: 1})}
               )
      end
    end
  end
end
