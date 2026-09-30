defmodule ClaudeWrapper.Commands.AuthStatusTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Commands.Auth
  alias ClaudeWrapper.Config

  setup do
    directory = Path.join(System.tmp_dir!(), "claude-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    binary = Path.join(directory, "claude-fixture")
    File.write!(binary, "#!/bin/sh\ncat \"$0.json\"\n")
    File.chmod!(binary, 0o755)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{binary: binary}
  end

  test "normalizes current camelCase fields and keeps unknown fields", %{binary: binary} do
    status =
      status(binary, %{
        "loggedIn" => true,
        "authMethod" => "claude.ai",
        "apiProvider" => "firstParty",
        "email" => "operator@example.com",
        "orgId" => "example-org",
        "orgName" => "Example",
        "subscriptionType" => "max",
        "futureField" => 42
      })

    assert status == %{
             logged_in: true,
             auth_method: "claude.ai",
             api_provider: "firstParty",
             email: "operator@example.com",
             org_id: "example-org",
             org_name: "Example",
             subscription_type: "max",
             extra: %{"futureField" => 42}
           }
  end

  test "keeps legacy snake_case output supported", %{binary: binary} do
    status =
      status(binary, %{
        "logged_in" => true,
        "auth_method" => "api_key",
        "api_provider" => "anthropic",
        "email" => "legacy@example.com",
        "org_id" => "legacy-org",
        "org_name" => "Legacy",
        "subscription_type" => "pro"
      })

    assert status.logged_in
    assert status.auth_method == "api_key"
    assert status.api_provider == "anthropic"
    assert status.email == "legacy@example.com"
    assert status.org_id == "legacy-org"
    assert status.org_name == "Legacy"
    assert status.subscription_type == "pro"
    assert status.extra == %{}
  end

  test "current spelling wins over legacy spelling, including explicit false", %{binary: binary} do
    status =
      status(binary, %{
        "loggedIn" => false,
        "logged_in" => true,
        "authMethod" => "current",
        "auth_method" => "legacy",
        "apiProvider" => nil,
        "api_provider" => "legacy"
      })

    refute status.logged_in
    assert status.auth_method == "current"
    assert status.api_provider == nil
    assert status.extra == %{}
  end

  defp status(binary, data) do
    File.write!(binary <> ".json", Jason.encode!(data))
    assert {:ok, status} = Auth.status(Config.new(binary: binary))
    status
  end
end
