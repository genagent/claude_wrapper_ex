defmodule ClaudeWrapper.AgentsTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Agents
  alias ClaudeWrapper.Agents.{Definition, Summary}

  setup do
    root = Path.join(System.tmp_dir!(), "cwx_agents_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp write_agent(dir, file_stem, contents) do
    File.mkdir_p!(dir)
    path = Path.join(dir, file_stem <> ".md")
    File.write!(path, contents)
    path
  end

  defp fixture(root) do
    write_agent(
      root,
      "rust-qa",
      "---\nname: rust-qa\ndescription: Rust quality gate\ntools: Read, Grep, Bash\nmodel: sonnet\n---\n\nYou are a Rust quality gate.\n"
    )

    write_agent(root, "no-frontmatter", "Just a body, no frontmatter at all.\n")

    write_agent(
      root,
      "minimal",
      "---\nname: minimal\ndescription: Minimal agent\n---\nBody here.\n"
    )

    write_agent(
      root,
      "weird",
      "---\nname: weird\ndescription: has extras\ncustom_key: custom_value\n---\nbody\n"
    )

    # Non-md file should be ignored by list/1.
    File.write!(Path.join(root, "README.txt"), "ignore me")
    :ok
  end

  describe "home/0, at/1, root/1" do
    test "at/1 wraps an explicit root and root/1 reads it back" do
      a = Agents.at("/tmp/agents")
      assert a.root == "/tmp/agents"
      assert Agents.root(a) == "/tmp/agents"
    end

    test "home/0 resolves ~/.claude/agents" do
      assert {:ok, %Agents{root: root}} = Agents.home()
      assert String.ends_with?(root, Path.join([".claude", "agents"]))
    end
  end

  describe "list/1" do
    test "returns only .md files, sorted by file stem", %{root: root} do
      fixture(root)

      {:ok, summaries} = Agents.list(Agents.at(root))

      assert Enum.map(summaries, & &1.file_stem) == [
               "minimal",
               "no-frontmatter",
               "rust-qa",
               "weird"
             ]
    end

    test "returns empty when the root does not exist" do
      {:ok, summaries} = Agents.list(Agents.at("/no/such/agents/root"))
      assert summaries == []
    end

    test "parses typed metadata into a Summary", %{root: root} do
      fixture(root)

      {:ok, summaries} = Agents.list(Agents.at(root))
      rust_qa = Enum.find(summaries, &(&1.file_stem == "rust-qa"))

      assert %Summary{name: "rust-qa", description: "Rust quality gate", model: "sonnet"} =
               rust_qa

      assert rust_qa.tools == ["Read", "Grep", "Bash"]
      assert rust_qa.size_bytes > 0
      assert String.ends_with?(rust_qa.file_path, "rust-qa.md")
    end

    test "no frontmatter falls back to the file stem as name", %{root: root} do
      fixture(root)

      {:ok, summaries} = Agents.list(Agents.at(root))
      nf = Enum.find(summaries, &(&1.file_stem == "no-frontmatter"))

      assert nf.name == "no-frontmatter"
      assert nf.description == nil
      assert nf.tools == []
      assert nf.model == nil
    end
  end

  describe "get/2" do
    test "returns the full Definition with body", %{root: root} do
      fixture(root)

      {:ok, agent} = Agents.get(Agents.at(root), "rust-qa")

      assert %Definition{name: "rust-qa", model: "sonnet"} = agent
      assert agent.tools == ["Read", "Grep", "Bash"]
      assert agent.body == "You are a Rust quality gate."
    end

    test "no frontmatter returns the whole file as body", %{root: root} do
      fixture(root)

      {:ok, agent} = Agents.get(Agents.at(root), "no-frontmatter")

      assert agent.body == "Just a body, no frontmatter at all."
      assert agent.name == "no-frontmatter"
      assert agent.tools == []
      assert agent.extra == %{}
    end

    test "unknown stem returns {:error, :not_found}", %{root: root} do
      fixture(root)
      assert Agents.get(Agents.at(root), "nope") == {:error, :not_found}
    end

    test "extra frontmatter keys round-trip as raw strings", %{root: root} do
      fixture(root)

      {:ok, agent} = Agents.get(Agents.at(root), "weird")
      assert agent.extra["custom_key"] == "custom_value"
    end

    test "empty-valued keys do not overwrite defaults", %{root: root} do
      write_agent(root, "empty-name", "---\nname:\ndescription: keeps stem as name\n---\nbody\n")

      {:ok, agent} = Agents.get(Agents.at(root), "empty-name")
      assert agent.name == "empty-name"
      assert agent.description == "keeps stem as name"
    end

    test "an opening --- with no close is treated as no frontmatter", %{root: root} do
      raw = "---\nname: x\nstill no close here\n"
      write_agent(root, "unclosed", raw)

      {:ok, agent} = Agents.get(Agents.at(root), "unclosed")
      # Conservative: whole file is the body, name falls back to stem.
      assert agent.name == "unclosed"
      assert agent.body == String.trim(raw)
    end

    test "list-valued frontmatter keys are tolerated via extra", %{root: root} do
      write_agent(
        root,
        "folded",
        "---\nname: folded\nskills:\n  - sandbox-preflight\n---\nbody\n"
      )

      {:ok, agent} = Agents.get(Agents.at(root), "folded")
      # The `skills:` key has no inline value, so it is skipped; the
      # list item line has no colon, so it is skipped too. Parse must
      # not fail.
      assert agent.name == "folded"
      assert agent.body == "body"
    end
  end

  describe "write/3" do
    test "creates a new agent that round-trips via get/2", %{root: root} do
      a = Agents.at(root)

      assert :ok =
               Agents.write(a, "my-agent",
                 name: "my-agent",
                 description: "does the thing",
                 tools: ["Read", "Bash"],
                 model: "sonnet",
                 body: "You are an agent."
               )

      {:ok, agent} = Agents.get(a, "my-agent")
      assert agent.name == "my-agent"
      assert agent.description == "does the thing"
      assert agent.tools == ["Read", "Bash"]
      assert agent.model == "sonnet"
      assert agent.body == "You are an agent."
    end

    test "accepts a map of attrs", %{root: root} do
      a = Agents.at(root)

      assert :ok = Agents.write(a, "as-map", %{description: "from a map", body: "b"})

      {:ok, agent} = Agents.get(a, "as-map")
      assert agent.description == "from a map"
      assert agent.body == "b"
    end

    test "overwrites an existing agent, replacing the whole file", %{root: root} do
      fixture(root)
      a = Agents.at(root)

      assert :ok = Agents.write(a, "rust-qa", description: "rewritten", body: "new body")

      {:ok, agent} = Agents.get(a, "rust-qa")
      assert agent.description == "rewritten"
      assert agent.body == "new body"
      # tools/model from the original are gone -- write replaces the file.
      assert agent.tools == []
      assert agent.model == nil
    end

    test "creates the root directory if missing", %{root: root} do
      a = Agents.at(Path.join(root, "nested/agents"))

      assert :ok = Agents.write(a, "foo", body: "body")
      assert {:ok, agent} = Agents.get(a, "foo")
      assert agent.body == "body"
    end

    test "defaults name to the file stem when absent", %{root: root} do
      a = Agents.at(root)
      assert :ok = Agents.write(a, "my-stem", body: "b")

      {:ok, agent} = Agents.get(a, "my-stem")
      assert agent.name == "my-stem"
    end

    test "preserves extra keys, sorted, after the typed keys", %{root: root} do
      a = Agents.at(root)

      assert :ok =
               Agents.write(a, "ex",
                 name: "n",
                 description: "d",
                 tools: ["t1", "t2"],
                 model: "haiku",
                 body: "body",
                 extra: %{"zzz_last" => "v", "aaa_first" => "v"}
               )

      raw = File.read!(Path.join(root, "ex.md"))
      lines = String.split(raw, "\n")

      assert Enum.at(lines, 0) == "---"
      assert Enum.at(lines, 1) == "name: n"
      assert Enum.at(lines, 2) == "description: d"
      assert Enum.at(lines, 3) == "tools: t1, t2"
      assert Enum.at(lines, 4) == "model: haiku"
      assert Enum.at(lines, 5) == "aaa_first: v"
      assert Enum.at(lines, 6) == "zzz_last: v"
      assert Enum.at(lines, 7) == "---"

      {:ok, agent} = Agents.get(a, "ex")
      assert agent.extra == %{"aaa_first" => "v", "zzz_last" => "v"}
    end

    test "omits optional keys when unset", %{root: root} do
      a = Agents.at(root)
      assert :ok = Agents.write(a, "min", body: "body only")

      raw = File.read!(Path.join(root, "min.md"))
      refute raw =~ "description:"
      refute raw =~ "tools:"
      refute raw =~ "model:"
    end

    test "rejects path-traversal and reserved stems", %{root: root} do
      a = Agents.at(root)

      for bad <- ["", ".", "..", "a/b", "a\\b", "a\0b"] do
        assert Agents.write(a, bad, body: "b") == {:error, {:invalid_stem, bad}}
      end
    end
  end

  describe "write_new/3" do
    test "errors with {:error, :exists} when the agent already exists", %{root: root} do
      fixture(root)
      assert Agents.write_new(Agents.at(root), "rust-qa", body: "body") == {:error, :exists}
    end

    test "succeeds for a fresh stem", %{root: root} do
      a = Agents.at(root)
      assert :ok = Agents.write_new(a, "brand-new", body: "hello")

      {:ok, agent} = Agents.get(a, "brand-new")
      assert agent.body == "hello"
    end

    test "rejects path-traversal stems before touching the filesystem", %{root: root} do
      assert Agents.write_new(Agents.at(root), "a/b", body: "b") ==
               {:error, {:invalid_stem, "a/b"}}
    end
  end

  describe "delete/2" do
    test "removes the file", %{root: root} do
      fixture(root)
      a = Agents.at(root)

      assert {:ok, _} = Agents.get(a, "rust-qa")
      assert :ok = Agents.delete(a, "rust-qa")
      assert Agents.get(a, "rust-qa") == {:error, :not_found}
    end

    test "unknown stem returns {:error, :not_found}", %{root: root} do
      fixture(root)
      assert Agents.delete(Agents.at(root), "nope") == {:error, :not_found}
    end

    test "rejects path-traversal stems", %{root: root} do
      a = Agents.at(root)

      for bad <- ["", ".", "..", "a/b", "a\\b"] do
        assert Agents.delete(a, bad) == {:error, {:invalid_stem, bad}}
      end
    end
  end
end
