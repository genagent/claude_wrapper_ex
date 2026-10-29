defmodule ClaudeWrapper.Runner.PortTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, Error, Query, StreamEvent}
  alias ClaudeWrapper.Runner.Port, as: PortRunner

  @moduletag :tmp_dir

  defp script(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  @result ~s({"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s"})

  describe "run/4 (#304)" do
    test "the CLI gets an empty stdin, so a stdin read returns at once", %{tmp_dir: dir} do
      # Without EOF on stdin this fake would block until the timeout.
      fake = script(dir, "reads_stdin", "cat >/dev/null\nprintf '%s\\n' '#{@result}'\n")
      started = System.monotonic_time(:millisecond)

      assert {:ok, %{result: "ok"}} =
               Query.execute(Query.new("p"), Config.new(binary: fake, timeout: 10_000))

      assert System.monotonic_time(:millisecond) - started < 5_000
    end

    test "returns stdout with stderr merged and the exit status", %{tmp_dir: dir} do
      fake = script(dir, "both", "echo out\necho err >&2\nexit 3\n")

      assert {:ok, {output, 3}} = PortRunner.run(fake, [], [stderr_to_stdout: true], 5_000)
      assert output =~ "out"
      assert output =~ "err"
    end

    test "honors cd and env, with nil and false unsetting", %{tmp_dir: dir} do
      System.put_env("PORT_TEST_B", "parent")
      System.put_env("PORT_TEST_C", "parent")

      on_exit(fn ->
        System.delete_env("PORT_TEST_B")
        System.delete_env("PORT_TEST_C")
      end)

      fake =
        script(
          dir,
          "env",
          ~S[printf '%s|%s|%s|%s' "$(pwd -P)" "$A" "${PORT_TEST_B-unset}" "${PORT_TEST_C-unset}"]
        )

      env = [{"A", "1"}, {"PORT_TEST_B", nil}, {"PORT_TEST_C", false}]

      assert {:ok, {output, 0}} = PortRunner.run(fake, [], [cd: dir, env: env], 5_000)
      assert output == "#{resolve(dir)}|1|unset|unset"
    end

    test "a missing or non-executable binary is :binary_not_found before spawning", %{
      tmp_dir: dir
    } do
      plain = Path.join(dir, "plain")
      File.write!(plain, "not executable")

      assert {:error, {:binary_not_found, :enoent}} =
               PortRunner.run(Path.join(dir, "missing"), [], [], 1_000)

      assert {:error, {:binary_not_found, :eacces}} = PortRunner.run(plain, [], [], 1_000)

      assert {:error, {:binary_not_found, :enoent}} =
               PortRunner.run("claude-wrapper-no-such-binary", [], [], 1_000)

      assert {:error, %Error{kind: :binary_not_found}} =
               Query.execute(Query.new("p"), Config.new(binary: Path.join(dir, "missing")))
    end

    test "a timeout still returns :timeout", %{tmp_dir: dir} do
      fake = script(dir, "slow", "sleep 5\n")
      assert {:error, :timeout} = PortRunner.run(fake, [], [], 200)
    end
  end

  describe "stream_lines/4 (#305)" do
    test "each argument is its own argv string, so long arguments are not joined", %{
      tmp_dir: dir
    } do
      fake =
        script(dir, "sizes", ~S(printf '{"type":"result","result":"%s %s"}\n' "${#1}" "${#2}"))

      big = String.duplicate("a", 100_000)

      events =
        fake
        |> PortRunner.stream_lines([big, big], [], 10_000)
        |> Enum.map(&StreamEvent.parse/1)

      assert [{:ok, %StreamEvent{data: %{"result" => "100000 100000"}}}] = events
    end
  end

  # macOS reports the realpath of a tmp dir under /private.
  defp resolve(path) do
    case System.cmd("/bin/sh", ["-c", "cd \"$1\" && pwd -P", "sh", path]) do
      {out, 0} -> String.trim(out)
      _ -> path
    end
  end
end
