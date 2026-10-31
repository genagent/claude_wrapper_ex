defmodule ClaudeWrapper.PromptStdinTest do
  # Not async: the prompt-file cleanup checks look at the shared tmp dir,
  # and sync modules run after every async one has finished.
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{Config, Error, Query, Retry, StreamEvent}

  @moduletag :tmp_dir

  # Reports the stdin length and argv count, and whether the prompt marker
  # is anywhere in argv.
  defp fake(dir, extra \\ "") do
    path = Path.join(dir, "fake_claude")

    File.write!(path, """
    #!/bin/sh
    #{extra}
    n=$(wc -c | tr -d ' ')
    case "$*" in *PROMPT-MARKER*) inargv=yes ;; *) inargv=no ;; esac
    printf '{"type":"result","subtype":"success","is_error":false,"session_id":"s","result":"stdin=%s argv=%s"}\\n' "$n" "$inargv"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp prompt_dirs, do: Path.wildcard(Path.join(System.tmp_dir!(), "claude-wrapper-prompt-*"))

  # Prompt directories created during the test and still present.
  setup do
    before = prompt_dirs()
    {:ok, new_prompt_dirs: fn -> prompt_dirs() -- before end}
  end

  defp execute(query, config) do
    {:ok, %{result: result}} = Query.execute(query, config)
    result
  end

  test "the prompt goes to stdin, not argv, and its file is removed", %{
    tmp_dir: dir,
    new_prompt_dirs: ctx_new
  } do
    prompt = "PROMPT-MARKER " <> String.duplicate("x", 2_097_152)
    config = Config.new(binary: fake(dir))

    assert execute(Query.new(prompt), config) == "stdin=#{byte_size(prompt)} argv=no"
    assert ctx_new.() == []
  end

  test "prompt_input: :argv keeps the prompt after --", %{tmp_dir: dir} do
    query = "PROMPT-MARKER" |> Query.new() |> Query.prompt_input(:argv)
    assert execute(query, Config.new(binary: fake(dir))) =~ "argv=yes"
  end

  test "stream/2 delivers on stdin and removes the file when the stream ends", %{
    tmp_dir: dir,
    new_prompt_dirs: ctx_new
  } do
    events =
      "PROMPT-MARKER hi"
      |> Query.new()
      |> Query.stream(Config.new(binary: fake(dir)))
      |> Enum.to_list()

    assert [%StreamEvent{type: "result", data: %{"result" => "stdin=16 argv=no"}}] = events
    assert ctx_new.() == []
  end

  test "the prompt is not in the process table while the CLI runs", %{tmp_dir: dir} do
    marker = Path.join(dir, "running")
    config = Config.new(binary: fake(dir, "touch '#{marker}'; sleep 1"))
    task = Task.async(fn -> Query.execute(Query.new("PROMPT-MARKER secret"), config) end)

    wait_for(fn -> File.exists?(marker) end)
    {ps, 0} = System.cmd("ps", ["-ax", "-ww", "-o", "args="])
    refute ps =~ "PROMPT-MARKER"
    assert {:ok, _} = Task.await(task)
  end

  test "the file is removed after a timeout", %{tmp_dir: dir, new_prompt_dirs: ctx_new} do
    config = Config.new(binary: fake(dir, "sleep 5"), timeout: 200)
    assert {:error, %Error{kind: :timeout}} = Query.execute(Query.new("p"), config)
    assert ctx_new.() == []
  end

  test "a missing binary is :binary_not_found before anything is written", %{
    tmp_dir: dir,
    new_prompt_dirs: ctx_new
  } do
    config = Config.new(binary: Path.join(dir, "missing"))
    assert {:error, %Error{kind: :binary_not_found}} = Query.execute(Query.new("p"), config)

    assert [%StreamEvent{type: "error", data: %{"error" => "spawn_rejected"}}] =
             Query.new("p") |> Query.stream(config) |> Enum.to_list()

    assert ctx_new.() == []
  end

  test "an oversized argv is a typed error that Retry does not retry", %{tmp_dir: dir} do
    query = "p" |> Query.new() |> Query.system_prompt(String.duplicate("s", 4_000_000))
    config = Config.new(binary: fake(dir))

    assert {:error, %Error{kind: :argument_list_too_long, reason: %{bytes: bytes}}} =
             error = Query.execute(query, config)

    assert bytes >= 4_000_000
    refute Retry.default_retry_on(error)
  end

  @tag :forcola_evidence
  test "Runner.Forcola delivers the prompt on stdin too", %{tmp_dir: dir} do
    config = Config.new(binary: fake(dir), runner: ClaudeWrapper.Runner.Forcola)
    assert execute(Query.new("PROMPT-MARKER hi"), config) == "stdin=16 argv=no"
  end

  defp wait_for(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && wait_for(fun, attempts - 1)
    end
  end
end
