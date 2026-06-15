defmodule ClaudeWrapper.Commands.ProjectTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Commands.Project

  # These tests exercise only arg composition via the @doc false builder.
  # They never invoke the real `claude project purge`, which deletes state.

  describe "module surface" do
    test "is loaded and exposes the expected functions" do
      Code.ensure_loaded!(Project)
      funcs = Project.__info__(:functions)

      assert {:purge, 1} in funcs
      assert {:purge, 2} in funcs
      assert {:purge_args, 1} in funcs
    end
  end

  describe "purge_args/1" do
    test "defaults to the bare subcommand" do
      assert Project.purge_args([]) == ["project", "purge"]
    end

    test "passes path as a positional" do
      assert Project.purge_args(path: "/tmp/old-project") ==
               ["project", "purge", "/tmp/old-project"]
    end

    test "emits --all and --yes" do
      assert Project.purge_args(all: true, yes: true) ==
               ["project", "purge", "--all", "--yes"]
    end

    test "dry_run with yes is a safe preview" do
      assert Project.purge_args(dry_run: true, yes: true) ==
               ["project", "purge", "--dry-run", "--yes"]
    end

    test "emits --interactive" do
      assert Project.purge_args(interactive: true) ==
               ["project", "purge", "--interactive"]
    end

    test "composes all flags with the path positional last" do
      assert Project.purge_args(
               path: "/proj",
               all: true,
               dry_run: true,
               interactive: true,
               yes: true
             ) ==
               [
                 "project",
                 "purge",
                 "--all",
                 "--dry-run",
                 "--interactive",
                 "--yes",
                 "/proj"
               ]
    end

    test "the path positional always lands last so it is unambiguous" do
      args = Project.purge_args(yes: true, path: "./me")
      assert List.last(args) == "./me"
    end

    test "omits flags that are falsy" do
      refute "--all" in Project.purge_args(all: false)
      refute "--dry-run" in Project.purge_args(yes: true)
    end
  end
end
