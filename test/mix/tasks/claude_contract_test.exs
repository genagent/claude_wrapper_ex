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
end
