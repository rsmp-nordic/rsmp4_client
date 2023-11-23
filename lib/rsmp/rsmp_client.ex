defmodule RsmpClient do
  @moduledoc false

  use GenServer

  require Logger

  def start_link([]) do
    {:ok, pid} = GenServer.start_link(__MODULE__, [])
    Logger.info("RSMP: Starting client with pid #{inspect(pid)}")

    {:ok, pid}
  end

  def init([]) do
    interval = Application.get_env(:rsmp, :interval)
    emqtt_opts = Application.get_env(:rsmp, :emqtt) |> Enum.into(%{})
    id = "tlc_#{SecureRandom.hex(4)}"

    options =
      Map.merge(emqtt_opts, %{
        name: String.to_atom(id),
        clientid: id,
        will_topic: "state/#{id}",
        will_payload: :erlang.term_to_binary(0),
        will_retain: true
      })

    Logger.info("RSMP: starting emqtt")
    {:ok, pid} = :emqtt.start_link(options)

    state = %{
      id: id,
      pid: pid,
      interval: interval,
      timer: nil,
      statuses: %{
        "main/system/temperature" => 21,
        "main/system/plan" => 1
      }
    }

    {:ok, set_timer(state), {:continue, :start_emqtt}}
  end

  def handle_continue(:start_emqtt, %{pid: pid, id: clientid} = state) do
    {:ok, _} = :emqtt.connect(pid)

    # subscribe to commands
    {:ok, _, _} = :emqtt.subscribe(pid, {"command/#{clientid}/plan", 1})

    # say hello
    :emqtt.publish(
      pid,
      "state/#{clientid}",
      :erlang.term_to_binary(1),
      retain: true
    )

    {:noreply, state}
  end

  def handle_info(:tick, state) do
    # status_temperature(pid, topic)
    # {:noreply, set_timer(state)}
    {:noreply, state}
  end

  def handle_info({:publish, publish}, state) do
    # IO.inspect(publish)
    handle_publish(parse_topic(publish), publish, state)
  end

  defp handle_publish(
         ["command", _, "plan" = command],
         %{payload: payload, properties: properties},
         state
       ) do

    path = "main/system/plan"
    plan = :erlang.binary_to_term(payload)
    state = %{state | statuses: Map.put(state.statuses, path, plan)}

    pid = state[:pid]
    response_topic = properties[:"Response-Topic"]
    command_id = properties[:"Correlation-Data"]


    if response_topic && command_id do
      response = if plan >= 0 && plan < 10 do
        Logger.info(
          "RSMP: Received '#{command}' command #{command_id}: Switching to plan: #{plan}"
        )
        {:ok, plan, ""}
      else
        Logger.info(
          "RSMP: Received '#{command}' command #{command_id}: Cannot switch to plan: #{plan}"
    )
        {:not_found, plan, "Plan #{plan} not found"}
      end

      properties = %{
        "Correlation-Data": command_id
      }

      {:ok, _pkt_id} =
        :emqtt.publish(
          # Client
          pid,
          # Topic
          response_topic,
          # Properties
          properties,
          # Payload
          :erlang.term_to_binary(response),
          # Opts
          retain: false,
          qos: 2
        )
    end

    publish_status(state, path)
    

    data = %{topic: "status", changes: %{path => plan}}
    Phoenix.PubSub.broadcast(Rsmp.PubSub, "rsmp", data)

    # {:noreply, set_timer(new_state)}
    {:noreply, state}
  end

  defp handle_publish(_, _, state) do
    {:noreply, state}
  end

  defp parse_topic(%{topic: topic}) do
    String.split(topic, "/", trim: true)
  end

  defp set_timer(state) do
    if state.timer do
      Process.cancel_timer(state.timer)
    end

    timer = Process.send_after(self(), :tick, state.interval)
    %{state | timer: timer}
  end

  # api
  # from iex:
  # > Process.whereis(RSMP) |> RSMP.set_status("main","system",1,234)

  def get_id(pid) do
    GenServer.call(pid, :get_id)
  end

  def get_statuses(pid) do
    GenServer.call(pid, :get_statuses)
  end

  def get_status(pid, path) do
    GenServer.call(pid, {:get_status, path})
  end

  def set_status(pid, path, value) do
    GenServer.cast(pid, {:set_status, path, value})
  end

  def send_all_status(pid) do
    GenServer.cast(pid, {:send_all_status})
  end

  # server
  def handle_call(:get_id, _from, state) do
    {:reply, state[:id], state}
  end

  def handle_call(:get_statuses, _from, state) do
    {:reply, state[:statuses], state}
  end

  def handle_call({:get_status, path}, _from, state) do
    {:reply, state[:statuses][path], state}
  end

  def handle_cast({:set_status, path, value}, state) do
    state = %{state | statuses: Map.put(state.statuses, path, value)}
    publish_status(state, path)
    {:noreply, state}
  end

  def handle_cast({:send_all_status}, state) do
    publish_all_status(state)
    {:noreply, state}
  end

  # internal
  defp publish_status(state, path) do
    :emqtt.publish(
      # Client
      state.pid,
      # Topic
      "status/#{state.id}/#{path}",
      # Properties
      %{},
      # Payload
      :erlang.term_to_binary(state.statuses[path]),
      # Opts
      retain: true,
      qos: 1
    )
  end

  defp publish_all_status(state) do
    :emqtt.publish(
      # Client
      state.pid,
      # Topic
      "status/#{state.id}/all",
      # Properties
      %{},
      # Payload
      :erlang.term_to_binary(state.status),
      # Opts
      retain: true,
      qos: 1
    )
  end
end
