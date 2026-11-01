defmodule Mix.Tasks.Claude.ContractTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Commands.Auth
  alias ClaudeWrapper.{Config, Error}
  alias Mix.Tasks.Claude.Contract

  test "checks documented flags using only help" do
    {binary, _marker} = fake_cli()
    assert Contract.check(binary, [{[], ["--model", "sonnet", "--", "--prompt-text"]}]) == []
  end

  test "removed flags fail the contract" do
    {binary, _marker} = fake_cli()
    assert [finding] = Contract.check(binary, [{[], ["--removed-option"]}])
    assert finding =~ "--removed-option"
  end

  test "unknown subcommands cannot pass with root help" do
    {binary, _marker} = fake_cli()
    assert [finding] = Contract.check(binary, [{["auth", "removed"], ["auth", "removed"]}])
    assert finding =~ "no usable command help"
  end

  test "hidden options must produce their own missing operand error" do
    {binary, _marker} = fake_cli()
    assert Contract.check(binary, [{[], ["--system-prompt-file", "file"]}]) == []
    {removed, _marker} = fake_cli("unknown option")
    assert [_finding] = Contract.check(removed, [{[], ["--system-prompt-file", "file"]}])
  end

  @subagent_hidden ~w(--append-subagent-system-prompt --append-subagent-system-prompt-file --advisor)

  @issue_328_flags ~w(--restricted --permission-prompts --system-prompt-snapshot --autocompact
                      --allow-dangerously-skip-permissions --chrome --no-chrome
                      --forward-subagent-text --append-subagent-system-prompt
                      --append-subagent-system-prompt-file --advisor --prompt-suggestions)

  test "the #328 hidden value flags are probed for their own missing operand error" do
    assert Enum.all?(@subagent_hidden, &(&1 in Contract.hidden_value_flags()))
    binary = echoing_cli(nil)

    for flag <- @subagent_hidden do
      assert Contract.check(binary, [{[], [flag, "value", "--", "prompt"]}]) == []
    end
  end

  test "a #328 hidden flag the CLI does not recognize fails the contract" do
    for flag <- @subagent_hidden do
      binary = echoing_cli(flag)
      assert [finding] = Contract.check(binary, [{[], [flag, "value"]}])
      assert finding =~ "emitted #{flag} is not documented"
    end
  end

  test "an unlisted, non-hidden flag still fails" do
    binary = echoing_cli(nil)
    assert [finding] = Contract.check(binary, [{[], ["--advisor-typo", "x"]}])
    assert finding =~ "--advisor-typo"
  end

  test "query specimens exercise every #328 flag, including both chrome spellings" do
    emitted =
      Contract.query_specs()
      |> Enum.flat_map(fn {[], args} -> Enum.take_while(args, &(&1 != "--")) end)

    for flag <- @issue_328_flags do
      assert flag in emitted, "#{flag} is not exercised by a contract specimen"
    end

    assert Enum.any?(Contract.query_specs(), fn {[], args} ->
             subsequence?(["--prompt-suggestions", "false"], args)
           end)
  end

  test "token-from-stdin setup is rejected before starting a process" do
    {binary, marker} = fake_cli()

    assert {:error, %Error{kind: :unsupported_command, reason: :setup_token_from_stdin}} =
             Auth.setup_token(Config.new(binary: binary), "synthetic-private-token")

    refute File.exists?(marker)
  end

  defp fake_cli(hidden_reply \\ "error: option '--system-prompt-file <file>' argument missing") do
    dir =
      Path.join(
        System.tmp_dir!(),
        "claude-contract-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    binary = Path.join(dir, "claude")
    marker = Path.join(dir, "invoked")

    File.write!(binary, """
    #!/bin/sh
    printf invoked > '#{marker}'
    case "$*" in
      *--help) printf 'Usage: claude [options] [prompt]\\nOptions:\\n  --model <MODEL>\\n  --help\\n'; exit 0 ;;
    esac
    printf '%s\\n' "#{hidden_reply}"
    exit 1
    """)

    File.chmod!(binary, 0o755)
    {binary, marker}
  end

  # A fake whose `-p <flag>` probe reports a missing operand for that flag,
  # except for `unknown_flag`, which it reports as unknown.
  defp echoing_cli(unknown_flag) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "claude-contract-echo-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    binary = Path.join(dir, "claude")

    File.write!(binary, """
    #!/bin/sh
    case "$*" in
      *--help) printf 'Usage: claude [options] [prompt]\\nOptions:\\n  --model <MODEL>\\n  --help\\n'; exit 0 ;;
    esac
    if [ "$2" = "#{unknown_flag}" ]; then
      printf "error: unknown option '%s'\\n" "$2"
    else
      printf "error: option '%s <value>' argument missing\\n" "$2"
    fi
    exit 1
    """)

    File.chmod!(binary, 0o755)
    binary
  end

  defp subsequence?(sub, list) do
    list
    |> Enum.chunk_every(length(sub), 1, :discard)
    |> Enum.any?(&(&1 == sub))
  end
end
