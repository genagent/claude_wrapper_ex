defmodule ClaudeWrapper.SkillsTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Skills
  alias ClaudeWrapper.Skills.{Skill, Summary}

  setup do
    root = Path.join(System.tmp_dir!(), "cwx_skills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp write_skill(root, dir_stem, contents) do
    dir = Path.join(root, dir_stem)
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, contents)
    path
  end

  defp fixture(root) do
    write_skill(
      root,
      "recall",
      "---\nname: recall\ndescription: Search mente for memories\n---\n\nSearch for: $ARGUMENTS\n"
    )

    write_skill(root, "no-frontmatter", "Just a body, no frontmatter at all.\n")

    write_skill(
      root,
      "weird",
      "---\nname: weird\ndescription: has extras\ncustom_key: custom_value\n---\nbody\n"
    )

    # A skill with bundled assets (scripts/).
    write_skill(root, "bundled", "---\nname: bundled\ndescription: has scripts\n---\nbody\n")
    scripts = Path.join([root, "bundled", "scripts"])
    File.mkdir_p!(scripts)
    File.write!(Path.join(scripts, "helper.sh"), "#!/bin/sh\n")

    # A directory without SKILL.md should be ignored.
    bogus = Path.join(root, "not-a-skill")
    File.mkdir_p!(bogus)
    File.write!(Path.join(bogus, "README.md"), "not a skill")

    # A non-directory entry at the root should be ignored.
    File.write!(Path.join(root, "loose-file.md"), "ignore me")
    :ok
  end

  describe "home/0, at/1, root/1" do
    test "at/1 wraps an explicit root and root/1 reads it back" do
      s = Skills.at("/tmp/skills")
      assert s.root == "/tmp/skills"
      assert Skills.root(s) == "/tmp/skills"
    end

    test "home/0 resolves ~/.claude/skills" do
      assert {:ok, %Skills{root: root}} = Skills.home()
      assert String.ends_with?(root, Path.join([".claude", "skills"]))
    end
  end

  describe "list/1" do
    test "returns only skill dirs, sorted by dir stem", %{root: root} do
      fixture(root)

      {:ok, summaries} = Skills.list(Skills.at(root))

      assert Enum.map(summaries, & &1.dir_stem) == [
               "bundled",
               "no-frontmatter",
               "recall",
               "weird"
             ]
    end

    test "returns empty when the root does not exist" do
      {:ok, summaries} = Skills.list(Skills.at("/no/such/skills/root"))
      assert summaries == []
    end

    test "parses typed metadata into a Summary", %{root: root} do
      fixture(root)

      {:ok, summaries} = Skills.list(Skills.at(root))
      recall = Enum.find(summaries, &(&1.dir_stem == "recall"))

      assert %Summary{name: "recall", description: "Search mente for memories"} = recall
      assert recall.size_bytes > 0
      assert recall.has_assets == false
      assert String.ends_with?(recall.dir_path, "recall")
      assert String.ends_with?(recall.file_path, Path.join("recall", "SKILL.md"))
    end

    test "detects bundled assets beside SKILL.md", %{root: root} do
      fixture(root)

      {:ok, summaries} = Skills.list(Skills.at(root))
      bundled = Enum.find(summaries, &(&1.dir_stem == "bundled"))

      assert bundled.has_assets == true
    end

    test "no frontmatter falls back to the dir stem as name", %{root: root} do
      fixture(root)

      {:ok, summaries} = Skills.list(Skills.at(root))
      nf = Enum.find(summaries, &(&1.dir_stem == "no-frontmatter"))

      assert nf.name == "no-frontmatter"
      assert nf.description == nil
    end

    test "ignores directories without a SKILL.md", %{root: root} do
      fixture(root)

      {:ok, summaries} = Skills.list(Skills.at(root))
      refute Enum.any?(summaries, &(&1.dir_stem == "not-a-skill"))
    end

    test "ignores non-directory entries at the root", %{root: root} do
      fixture(root)

      {:ok, summaries} = Skills.list(Skills.at(root))
      refute Enum.any?(summaries, &(&1.dir_stem == "loose-file.md"))
    end
  end

  describe "get/2" do
    test "returns the full Skill with body", %{root: root} do
      fixture(root)

      {:ok, skill} = Skills.get(Skills.at(root), "recall")

      assert %Skill{name: "recall"} = skill
      assert skill.body == "Search for: $ARGUMENTS"
      assert skill.has_assets == false
    end

    test "no frontmatter returns the whole file as body", %{root: root} do
      fixture(root)

      {:ok, skill} = Skills.get(Skills.at(root), "no-frontmatter")

      assert skill.body == "Just a body, no frontmatter at all."
      assert skill.name == "no-frontmatter"
      assert skill.extra == %{}
    end

    test "unknown stem returns a :not_found error", %{root: root} do
      fixture(root)

      assert {:error, %ClaudeWrapper.Error{kind: :not_found, reason: "nope"}} =
               Skills.get(Skills.at(root), "nope")
    end

    test "extra frontmatter keys round-trip as raw strings", %{root: root} do
      fixture(root)

      {:ok, skill} = Skills.get(Skills.at(root), "weird")
      assert skill.extra["custom_key"] == "custom_value"
    end

    test "reports bundled assets on the full record", %{root: root} do
      fixture(root)

      {:ok, skill} = Skills.get(Skills.at(root), "bundled")
      assert skill.has_assets == true
    end

    test "empty-valued keys do not overwrite defaults", %{root: root} do
      write_skill(root, "empty-name", "---\nname:\ndescription: keeps stem as name\n---\nbody\n")

      {:ok, skill} = Skills.get(Skills.at(root), "empty-name")
      assert skill.name == "empty-name"
      assert skill.description == "keeps stem as name"
    end

    test "an opening --- with no close is treated as no frontmatter", %{root: root} do
      raw = "---\nname: x\nstill no close here\n"
      write_skill(root, "unclosed", raw)

      {:ok, skill} = Skills.get(Skills.at(root), "unclosed")
      # Conservative: whole file is the body, name falls back to stem.
      assert skill.name == "unclosed"
      assert skill.body == String.trim(raw)
    end

    test "list-valued frontmatter keys are tolerated", %{root: root} do
      write_skill(
        root,
        "folded",
        "---\nname: folded\nallowed-tools:\n  - Read\n---\nbody\n"
      )

      {:ok, skill} = Skills.get(Skills.at(root), "folded")
      # The `allowed-tools:` key has no inline value, so it is skipped;
      # the list item line has no colon, so it is skipped too. Parse
      # must not fail.
      assert skill.name == "folded"
      assert skill.body == "body"
    end
  end
end
