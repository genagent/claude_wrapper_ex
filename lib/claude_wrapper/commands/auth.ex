defmodule ClaudeWrapper.Commands.Auth do
  @moduledoc """
  Authentication commands -- login, logout, status, token setup.
  """

  alias ClaudeWrapper.Config

  @type auth_status :: %{
          logged_in: boolean(),
          auth_method: String.t() | nil,
          api_provider: String.t() | nil,
          email: String.t() | nil,
          org_id: String.t() | nil,
          org_name: String.t() | nil,
          subscription_type: String.t() | nil,
          extra: map()
        }

  @doc """
  Check authentication status.

  Returns parsed status if the CLI supports JSON output, raw text otherwise.
  """
  @spec status(Config.t()) :: {:ok, auth_status()} | {:error, term()}
  def status(%Config{} = config) do
    args = Config.base_args(config) ++ ["auth", "status", "--output-format", "json"]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, data} ->
            {:ok,
             %{
               logged_in: data["logged_in"] || false,
               auth_method: data["auth_method"],
               api_provider: data["api_provider"],
               email: data["email"],
               org_id: data["org_id"],
               org_name: data["org_name"],
               subscription_type: data["subscription_type"],
               extra:
                 Map.drop(data, [
                   "logged_in",
                   "auth_method",
                   "api_provider",
                   "email",
                   "org_id",
                   "org_name",
                   "subscription_type"
                 ])
             }}

          {:error, _} ->
            {:ok,
             %{
               logged_in: true,
               auth_method: nil,
               api_provider: nil,
               email: nil,
               org_id: nil,
               org_name: nil,
               subscription_type: nil,
               extra: %{"raw" => String.trim(output)}
             }}
        end

      {output, code} ->
        {:error, {:exit, code, output}}
    end
  end

  @doc """
  Login via browser. This is interactive -- the CLI will open a browser.
  """
  @spec login(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def login(%Config{} = config) do
    args = Config.base_args(config) ++ ["auth", "login"]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Logout.
  """
  @spec logout(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def logout(%Config{} = config) do
    args = Config.base_args(config) ++ ["auth", "logout"]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Set up an API token directly.
  """
  @spec setup_token(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def setup_token(%Config{} = config, token) do
    args = Config.base_args(config) ++ ["auth", "setup-token"]

    # Token is passed via stdin, so we use Port instead of System.cmd
    port_opts =
      [:binary, :exit_status, {:args, args}] ++
        if(config.working_dir, do: [{:cd, String.to_charlist(config.working_dir)}], else: [])

    port = Port.open({:spawn_executable, config.binary}, port_opts)
    Port.command(port, token <> "\n")

    receive do
      {^port, {:exit_status, 0}} -> {:ok, "token configured"}
      {^port, {:exit_status, code}} -> {:error, {:exit, code, ""}}
    after
      30_000 ->
        send(port, {self(), :close})
        {:error, :timeout}
    end
  end
end
