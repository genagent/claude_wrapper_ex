if Code.ensure_loaded?(Anubis.Server) do
  # ── Tool Components ─────────────────────────────────────────

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Configure do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:working_dir, :string, description: "working directory for agents")
      field(:model, :string, description: "default model (e.g. sonnet, opus, haiku)")

      field(:context, :string,
        description: "global system prompt prepended to every agent's role"
      )

      field(:permission_mode, :string,
        description: "permission mode (auto, bypass_permissions, default)"
      )
    end

    @impl true
    def execute(params, frame) do
      opts =
        params
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Enum.map(fn
          {:permission_mode, v} -> {:permission_mode, String.to_existing_atom(v)}
          pair -> pair
        end)

      ClaudeWrapper.Workshop.configure(opts)
      {:reply, Response.text(Response.tool(), "Configured."), frame}
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.CreateAgent do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:name, :string,
        required: true,
        description: "agent name (e.g. impl, reviewer, tests)"
      )

      field(:role, :string, description: "role description / agent-specific system prompt")
      field(:model, :string, description: "model override for this agent")
      field(:max_turns, :integer, description: "max conversation turns per send")

      field(:permission_mode, :string,
        description: "permission mode (auto, bypass_permissions, default)"
      )

      field(:allowed_tools, {:list, :string},
        description: "list of allowed tools (e.g. Read, Bash)"
      )
    end

    @impl true
    def execute(%{name: name} = params, frame) do
      atom_name = String.to_atom(name)
      role = Map.get(params, :role)

      opts =
        params
        |> Map.drop([:name, :role])
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Enum.map(fn
          {:permission_mode, v} -> {:permission_mode, String.to_existing_atom(v)}
          pair -> pair
        end)

      ClaudeWrapper.Workshop.agent(atom_name, role, opts)
      {:reply, Response.text(Response.tool(), "Agent #{name} created."), frame}
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Ask do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:agent, :string, required: true, description: "agent name")
      field(:prompt, :string, required: true, description: "message to send")
    end

    @impl true
    def execute(%{agent: name, prompt: prompt}, frame) do
      atom_name = String.to_existing_atom(name)

      case ClaudeWrapper.Workshop.ask(atom_name, prompt) do
        {:error, reason} ->
          {:reply, Response.error(Response.tool(), inspect(reason)), frame}

        _name ->
          text = ClaudeWrapper.Workshop.result(atom_name) || "(no response)"
          {:reply, Response.text(Response.tool(), text), frame}
      end
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Cast do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:agent, :string, required: true, description: "agent name")
      field(:prompt, :string, required: true, description: "message to send asynchronously")
    end

    @impl true
    def execute(%{agent: name, prompt: prompt}, frame) do
      atom_name = String.to_existing_atom(name)

      case ClaudeWrapper.Workshop.cast(atom_name, prompt) do
        :ok ->
          {:reply,
           Response.text(Response.tool(), "Cast to #{name}. Use await to get the result."), frame}

        {:error, reason} ->
          {:reply, Response.error(Response.tool(), inspect(reason)), frame}
      end
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Await do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:agent, :string, required: true, description: "agent name to wait for")

      field(:timeout, :integer,
        description: "max milliseconds to wait (default: 120000). 0 to just check status."
      )
    end

    @impl true
    def execute(%{agent: name} = params, frame) do
      atom_name = String.to_existing_atom(name)
      timeout = Map.get(params, :timeout, 120_000)

      info = ClaudeWrapper.Workshop.info(atom_name)

      if info.status == :idle do
        text = ClaudeWrapper.Workshop.result(atom_name) || "(no result yet)"
        {:reply, Response.text(Response.tool(), text), frame}
      else
        if timeout == 0 do
          {:reply,
           Response.text(
             Response.tool(),
             "#{name} is still working. Call await again later, or use status to check."
           ), frame}
        else
          ClaudeWrapper.Workshop.await(atom_name, timeout)
          text = ClaudeWrapper.Workshop.result(atom_name) || "(no result)"
          {:reply, Response.text(Response.tool(), text), frame}
        end
      end
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.AwaitAll do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:timeout, :integer,
        description: "max milliseconds to wait per agent (default: 120000). 0 to just check."
      )
    end

    @impl true
    def execute(params, frame) do
      timeout = Map.get(params, :timeout, 120_000)
      agents = ClaudeWrapper.Workshop.agents()

      any_busy? =
        Enum.any?(agents, fn name ->
          ClaudeWrapper.Workshop.info(name).status == :working
        end)

      if any_busy? and timeout > 0 do
        ClaudeWrapper.Workshop.await_all(timeout)
      end

      results = collect_results(agents)
      {:reply, Response.text(Response.tool(), results), frame}
    end

    defp collect_results(agents) do
      Enum.map_join(agents, "\n\n", fn name ->
        info = ClaudeWrapper.Workshop.info(name)
        status = if info.status == :working, do: " (still working)", else: ""
        text = ClaudeWrapper.Workshop.result(name)
        "## #{name}#{status}\n#{text || "(no result yet)"}"
      end)
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Status do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      agents = ClaudeWrapper.Workshop.agents()

      if agents == [] do
        {:reply, Response.text(Response.tool(), "No agents."), frame}
      else
        lines =
          Enum.map_join(agents, "\n", fn name ->
            info = ClaudeWrapper.Workshop.info(name)
            status = info.status
            model = info.model || "default"
            cost = info.cost
            turns = info.turns
            "#{name}: #{status} | model=#{model} | $#{Float.round(cost, 2)} | #{turns} turns"
          end)

        {:reply, Response.text(Response.tool(), lines), frame}
      end
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Result do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:agent, :string, required: true, description: "agent name")
    end

    @impl true
    def execute(%{agent: name}, frame) do
      atom_name = String.to_existing_atom(name)
      text = ClaudeWrapper.Workshop.result(atom_name) || "(no result)"
      {:reply, Response.text(Response.tool(), text), frame}
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Pipe do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:from, :string, required: true, description: "source agent name")
      field(:to, :string, required: true, description: "target agent name")
      field(:message, :string, description: "framing message for what the target should do")
    end

    @impl true
    def execute(%{from: from, to: to} = params, frame) do
      from_atom = String.to_existing_atom(from)
      to_atom = String.to_existing_atom(to)
      message = Map.get(params, :message)

      case ClaudeWrapper.Workshop.pipe(from_atom, to_atom, message) do
        {:error, reason} ->
          {:reply, Response.error(Response.tool(), inspect(reason)), frame}

        _name ->
          text = ClaudeWrapper.Workshop.result(to_atom) || "(no result)"
          {:reply, Response.text(Response.tool(), text), frame}
      end
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Fan do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:message, :string, required: true, description: "message to send to all agents")
      field(:agents, {:list, :string}, required: true, description: "list of agent names")
    end

    @impl true
    def execute(%{message: message, agents: agents}, frame) do
      atom_names = Enum.map(agents, &String.to_existing_atom/1)
      ClaudeWrapper.Workshop.fan(message, atom_names)
      names = Enum.join(agents, ", ")

      {:reply, Response.text(Response.tool(), "Sent to #{names}. Use await_all to collect."),
       frame}
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Info do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:agent, :string, required: true, description: "agent name")
    end

    @impl true
    def execute(%{agent: name}, frame) do
      atom_name = String.to_existing_atom(name)
      info = ClaudeWrapper.Workshop.info(atom_name)
      {:reply, Response.json(Response.tool(), info), frame}
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Agents do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      agents = ClaudeWrapper.Workshop.agents()
      text = if agents == [], do: "No agents.", else: Enum.map_join(agents, ", ", &to_string/1)
      {:reply, Response.text(Response.tool(), text), frame}
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Reset do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:agent, :string, required: true, description: "agent name to reset")
    end

    @impl true
    def execute(%{agent: name}, frame) do
      atom_name = String.to_existing_atom(name)
      ClaudeWrapper.Workshop.reset(atom_name)
      {:reply, Response.text(Response.tool(), "Agent #{name} reset."), frame}
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Dismiss do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:agent, :string, required: true, description: "agent name to remove")
    end

    @impl true
    def execute(%{agent: name}, frame) do
      atom_name = String.to_existing_atom(name)
      ClaudeWrapper.Workshop.dismiss(atom_name)
      {:reply, Response.text(Response.tool(), "Agent #{name} dismissed."), frame}
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.InspectAgent do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
      field(:agent, :string, required: true, description: "agent name")
      field(:prompt, :string, description: "sample prompt to show in the command")
    end

    @impl true
    def execute(%{agent: name} = params, frame) do
      atom_name = String.to_existing_atom(name)
      prompt = Map.get(params, :prompt, "PROMPT")
      cmd = ClaudeWrapper.Workshop.inspect_agent(atom_name, prompt)
      {:reply, Response.text(Response.tool(), cmd), frame}
    end
  end

  defmodule ClaudeWrapper.Workshop.MCP.Tools.Cost do
    @moduledoc false
    use Anubis.Server.Component, type: :tool
    alias Anubis.Server.Response

    schema do
    end

    @impl true
    def execute(_params, frame) do
      agents = ClaudeWrapper.Workshop.agents()

      lines =
        Enum.map_join(agents, "\n", fn name ->
          info = ClaudeWrapper.Workshop.info(name)
          "#{name}: $#{Float.round(info.cost, 2)} (#{info.turns} turns)"
        end)

      total = ClaudeWrapper.Workshop.total_cost()
      text = if lines == "", do: "No agents.", else: "#{lines}\nTotal: $#{Float.round(total, 2)}"
      {:reply, Response.text(Response.tool(), text), frame}
    end
  end

  # ── Server ──────────────────────────────────────────────────

  defmodule ClaudeWrapper.Workshop.MCP.Server do
    @moduledoc """
    MCP server exposing Workshop functions as tools.

    Allows a Claude Code session (or any MCP client) to orchestrate
    Workshop agents running in the same BEAM node.

    ## Starting from IEx

        ClaudeWrapper.Workshop.MCP.start(port: 4222)

    Then add to your Claude Code `.mcp.json`:

        {
          "mcpServers": {
            "workshop": {
              "type": "sse",
              "url": "http://localhost:4222/mcp"
            }
          }
        }
    """

    use Anubis.Server,
      name: "claude-workshop",
      version: "0.1.0",
      capabilities: [:tools]

    component(ClaudeWrapper.Workshop.MCP.Tools.Configure)
    component(ClaudeWrapper.Workshop.MCP.Tools.CreateAgent)
    component(ClaudeWrapper.Workshop.MCP.Tools.Ask)
    component(ClaudeWrapper.Workshop.MCP.Tools.Cast)
    component(ClaudeWrapper.Workshop.MCP.Tools.Await)
    component(ClaudeWrapper.Workshop.MCP.Tools.AwaitAll)
    component(ClaudeWrapper.Workshop.MCP.Tools.Status)
    component(ClaudeWrapper.Workshop.MCP.Tools.Result)
    component(ClaudeWrapper.Workshop.MCP.Tools.Pipe)
    component(ClaudeWrapper.Workshop.MCP.Tools.Fan)
    component(ClaudeWrapper.Workshop.MCP.Tools.Info)
    component(ClaudeWrapper.Workshop.MCP.Tools.Agents)
    component(ClaudeWrapper.Workshop.MCP.Tools.Reset)
    component(ClaudeWrapper.Workshop.MCP.Tools.Dismiss)
    component(ClaudeWrapper.Workshop.MCP.Tools.InspectAgent)
    component(ClaudeWrapper.Workshop.MCP.Tools.Cost)

    @impl true
    def init(_client_info, frame) do
      # Ensure Workshop is started
      ClaudeWrapper.Workshop.configure()
      {:ok, frame}
    end
  end

  # ── Router ──────────────────────────────────────────────────

  if Code.ensure_loaded?(Plug.Router) do
    defmodule ClaudeWrapper.Workshop.MCP.Router do
      @moduledoc false
      use Plug.Router

      alias Anubis.Server.Transport.StreamableHTTP
      alias ClaudeWrapper.Workshop.MCP, as: WorkshopMCP

      plug(:match)
      plug(:dispatch)

      # forward/2 calls Plug.init at compile time, but the Anubis server
      # supervisor sets up persistent_term at runtime. Dispatch manually
      # to defer init to request time.
      #
      # We also pass request_timeout from the stored config so the Plug's
      # GenServer.call timeout matches the server supervisor's timeout.
      # Without this, the Plug defaults to 30s and long tool calls fail
      # with "Server unavailable".
      match _ do
        if String.starts_with?(conn.request_path, "/mcp") do
          timeout = WorkshopMCP.request_timeout()

          opts =
            StreamableHTTP.Plug.init(
              server: ClaudeWrapper.Workshop.MCP.Server,
              request_timeout: timeout
            )

          StreamableHTTP.Plug.call(conn, opts)
        else
          send_resp(conn, 404, "not found")
        end
      end
    end
  end

  # ── Start Helper ────────────────────────────────────────────

  defmodule ClaudeWrapper.Workshop.MCP do
    @moduledoc """
    MCP server for Workshop. Exposes all Workshop functions as MCP tools.

    ## Quick start

        # From IEx (requires anubis_mcp, bandit, and plug deps):
        ClaudeWrapper.Workshop.MCP.start(port: 4222)

        # Then in .mcp.json for your Claude Code session:
        # {
        #   "mcpServers": {
        #     "workshop": {
        #       "type": "sse",
        #       "url": "http://localhost:4222/mcp"
        #     }
        #   }
        # }

    ## Available tools

    | Tool | Description |
    |---|---|
    | configure | Set global defaults (working_dir, model, context) |
    | create_agent | Create a named agent with role and options |
    | ask | Send a message and wait for response |
    | cast | Send a message asynchronously |
    | await / await_all | Wait for async results |
    | status | Dashboard of all agents |
    | result | Get last response from an agent |
    | pipe | Chain output from one agent to another |
    | fan | Send same message to multiple agents |
    | info | Detailed agent info as JSON |
    | agents | List all agent names |
    | reset / dismiss | Agent lifecycle management |
    | inspect_agent | Show the CLI command an agent would run |
    | cost | Show costs across all agents |
    """

    @default_request_timeout 300_000

    @doc false
    @spec request_timeout() :: pos_integer()
    def request_timeout do
      :persistent_term.get({__MODULE__, :request_timeout}, @default_request_timeout)
    end

    @doc """
    Start the Workshop MCP server over HTTP.

    ## Options

      * `:port` - HTTP port (default: 4222)
      * `:request_timeout` - MCP request timeout in ms (default: 300_000 / 5 min)
      * `:session_idle_timeout` - Session idle timeout in ms (default: 1_800_000 / 30 min)

    ## Example

        ClaudeWrapper.Workshop.MCP.start(port: 4222)
    """

    @spec start(keyword()) :: Supervisor.on_start()
    def start(opts \\ []) do
      port = Keyword.get(opts, :port, 4222)
      request_timeout = Keyword.get(opts, :request_timeout, @default_request_timeout)
      session_idle_timeout = Keyword.get(opts, :session_idle_timeout, 1_800_000)

      unless Code.ensure_loaded?(Bandit) do
        raise "Bandit is required for HTTP transport. Add {:bandit, \"~> 1.0\"} to your deps."
      end

      # Store timeout so the Router can pass it to the Plug
      :persistent_term.put({__MODULE__, :request_timeout}, request_timeout)

      # Ensure Workshop is running
      ClaudeWrapper.Workshop.configure()

      children = [
        {ClaudeWrapper.Workshop.MCP.Server,
         transport: {:streamable_http, start: true},
         request_timeout: request_timeout,
         session_idle_timeout: session_idle_timeout},
        {Bandit, plug: ClaudeWrapper.Workshop.MCP.Router, port: port, scheme: :http}
      ]

      Supervisor.start_link(children,
        strategy: :one_for_one,
        name: ClaudeWrapper.Workshop.MCP.Supervisor
      )
    end
  end
end
