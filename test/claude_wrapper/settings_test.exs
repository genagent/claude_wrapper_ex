defmodule ClaudeWrapper.SettingsTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Settings

  setup do
    base = Path.join(System.tmp_dir!(), "cwx_settings_#{System.unique_integer([:positive])}")
    user_root = Path.join(base, "user")
    project_root = Path.join(base, "project")
    File.mkdir_p!(user_root)
    File.mkdir_p!(project_root)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, user_root: user_root, project_root: project_root}
  end

  defp write_json(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(value))
  end

  describe "load/1" do
    test "loads only the user layer when others are absent", %{user_root: user_root} do
      write_json(Path.join(user_root, "settings.json"), %{"env" => %{"FOO" => "bar"}})

      {:ok, s} = Settings.load(user_root: user_root)

      assert s.user["env"]["FOO"] == "bar"
      assert s.user_local == nil
      assert s.project == nil
      assert s.project_local == nil
    end

    test "loads all four layers", %{user_root: user_root, project_root: project_root} do
      write_json(Path.join(user_root, "settings.json"), %{"layer" => "user"})
      write_json(Path.join(user_root, "settings.local.json"), %{"layer" => "user_local"})
      write_json(Path.join([project_root, ".claude", "settings.json"]), %{"layer" => "project"})

      write_json(Path.join([project_root, ".claude", "settings.local.json"]), %{
        "layer" => "project_local"
      })

      {:ok, s} = Settings.load(user_root: user_root, project_root: project_root)

      assert s.user["layer"] == "user"
      assert s.user_local["layer"] == "user_local"
      assert s.project["layer"] == "project"
      assert s.project_local["layer"] == "project_local"
    end

    test "missing files are not errors", %{user_root: user_root} do
      {:ok, s} = Settings.load(user_root: user_root)
      assert s.user == nil
      assert s.user_local == nil
    end

    test "no project_root means no project layers and nil project paths", %{user_root: user_root} do
      write_json(Path.join(user_root, "settings.json"), %{"x" => 1})

      {:ok, s} = Settings.load(user_root: user_root)

      assert s.user != nil
      assert s.project == nil
      assert s.project_local == nil
      assert s.paths.project == nil
      assert s.paths.project_local == nil
    end

    test "malformed JSON returns an error", %{user_root: user_root} do
      File.write!(Path.join(user_root, "settings.json"), "{not json")

      assert {:error, %ClaudeWrapper.Error{kind: :invalid_settings_json, reason: %{path: path}}} =
               Settings.load(user_root: user_root)

      assert path == Path.join(user_root, "settings.json")
    end

    test "paths reflect the configured roots", %{user_root: user_root, project_root: project_root} do
      {:ok, s} = Settings.load(user_root: user_root, project_root: project_root)

      assert s.paths.user == Path.join(user_root, "settings.json")
      assert s.paths.project == Path.join([project_root, ".claude", "settings.json"])
    end
  end

  describe "get/2, layers/0, filename/1" do
    test "get/2 indexes by layer", %{user_root: user_root} do
      write_json(Path.join(user_root, "settings.json"), %{"k" => "user"})
      write_json(Path.join(user_root, "settings.local.json"), %{"k" => "user_local"})

      {:ok, s} = Settings.load(user_root: user_root)

      assert Settings.get(s, :user)["k"] == "user"
      assert Settings.get(s, :user_local)["k"] == "user_local"
      assert Settings.get(s, :project) == nil
    end

    test "layers/0 lists all four in precedence order" do
      assert Settings.layers() == [:user, :user_local, :project, :project_local]
    end

    test "filename/1 maps layers to filenames" do
      assert Settings.filename(:user) == "settings.json"
      assert Settings.filename(:project) == "settings.json"
      assert Settings.filename(:user_local) == "settings.local.json"
      assert Settings.filename(:project_local) == "settings.local.json"
    end
  end

  describe "redact_env_values/1" do
    test "replaces env values but keeps keys and other fields" do
      v = %{
        "env" => %{"ANTHROPIC_API_KEY" => "sk-xxx", "DEBUG" => "1"},
        "permissions" => %{"allow" => ["Bash(ls *)"]}
      }

      redacted = Settings.redact_env_values(v)

      assert redacted["env"]["ANTHROPIC_API_KEY"] == "<redacted>"
      assert redacted["env"]["DEBUG"] == "<redacted>"
      assert redacted["permissions"]["allow"] == ["Bash(ls *)"]
    end

    test "is a no-op without an env field" do
      v = %{"permissions" => %{"allow" => []}}
      assert Settings.redact_env_values(v) == v
    end

    test "is a no-op on non-map input" do
      assert Settings.redact_env_values(["not", "a", "map"]) == ["not", "a", "map"]
    end

    test "is a no-op when env is not a map" do
      v = %{"env" => "weird-but-tolerated"}
      assert Settings.redact_env_values(v) == v
    end
  end
end
