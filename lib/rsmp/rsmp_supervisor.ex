defmodule RsmpSupervisor do
  use GenServer
  require Logger

  # Client

  # Starts the genserver, and registeres it under the name RSMP.
  # You can get the pid of the server with:
  # > pid = Process.whereis(RSMP)
  # 
  # You can the interact with the server using the pid
  # > pid |> RSMP.push(:pear)
  # :ok
  # > pid |> RSMP.pop()
  # :pear

  def start_link(default) when is_list(default) do
    {:ok,pid} = GenServer.start_link(__MODULE__, default)
    Process.register(pid, __MODULE__)
    {:ok,pid}
  end

  def clients(pid) do
    GenServer.call(pid, :clients)
  end

  # Callbacks

  @impl true
  def init(_rsmp) do
    statuses = []
    emqtt_opts = Application.get_env(:rsmp, :emqtt)
    {:ok, pid} = :emqtt.start_link(emqtt_opts)
    {:ok, _} = :emqtt.connect(pid)

    # Subscribe to statuses
    {:ok, _, _} = :emqtt.subscribe(pid, "status/#")
    {:ok, _, _} = :emqtt.subscribe(pid, "state/+")

    # Subscribe to our response topics
    client_id = emqtt_opts[:clientid]
    {:ok, _, _} = :emqtt.subscribe(pid, "response/#{client_id}/command/#")

    state = %{
      statuses: statuses,
      pid: pid,
      clients: %{},
      plan: nil
    }
    {:ok, state}
  end

  @impl true
  def handle_call(:clients, _from, state) do
    {:reply, state.clients, state}
  end

  defp parse_topic(%{topic: topic}) do
    String.split(topic, "/", trim: true)
  end

  @impl true
  def handle_info({:publish, packet}, state) do
    handle_publish(parse_topic(packet), packet, state)
  end

  def handle_info({:disconnected, _, _}, state) do
    Logger.info("Disconnected")
    {:noreply, state}
  end

  defp handle_publish(["state", id], %{payload: payload}, state) do
    client_state = :erlang.binary_to_term(payload)
    clients = Map.put(state.clients, id, client_state)
    data = %{topic: "clients", clients: clients}
    Phoenix.PubSub.broadcast(Rsmp.PubSub, "clients", data)
    {:noreply, %{ state | clients: clients } }
  end

  defp handle_publish(
         ["response", _supervisor_id, "command", id, command],
         %{payload: payload, properties: properties},
         state
       ) do
    if id == Application.get_env(:rsmp, :sensor_id) do
      status = :erlang.binary_to_term(payload)
      command_id = properties[:"Correlation-Data"]
      Logger.info("#{id}: Received response to '#{command}' command #{command_id}: #{status}")
    end

    {:noreply, state}
  end

  defp handle_publish(
         ["status", id, component, module, code],
         %{payload: payload, properties: _properties},
         state
       ) do
    if id == Application.get_env(:rsmp, :sensor_id) do
      status = :erlang.binary_to_term(payload)
      #command_id = properties[:"Correlation-Data"]
      Logger.info("#{id}: Received status #{component}/#{module}/#{code}: #{status}")
    end

    {:noreply, state}
  end

  defp handle_publish(
         ["status", id, "all"],
         %{payload: payload, properties: _properties},
         state
       ) do
    if id == Application.get_env(:rsmp, :sensor_id) do
      status = :erlang.binary_to_term(payload)
      Logger.info("#{id}: Received all status: #{inspect(status)}")
    end

    {:noreply, state}
  end

  # catch-all in case old retained messages are received from the broker
  defp handle_publish(_topic, %{payload: _payload, properties: _properties}, state) do
    {:noreply, state}
  end


end
