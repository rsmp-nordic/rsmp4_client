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
      statuses: %{
        "main/system/temperature" => 21,
        "main/system/plan" => 1
      }
    }

    {:ok, state, {:continue, :start_emqtt}}
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
    {:noreply, state}
  end

  def handle_info({:publish, publish}, state) do
    # IO.inspect(publish)
    handle_publish(parse_topic(publish), publish, state)
  end

  defp handle_publish(
         ["command", _, "plan"],
         %{payload: payload, properties: properties},
         state
       ) do

    options = %{
      path: "main/system/plan",
      plan: :erlang.binary_to_term(payload),
      response_topic: properties[:"Response-Topic"],
      command_id: properties[:"Correlation-Data"]
    }
    {:noreply, set_plan(state,options)}
  end

  def set_plan(state,%{
      path: path,
      plan: plan,
      response_topic: response_topic,
      command_id: command_id
    }) do
    
    current_plan = state[:statuses][path]

    {response,state} = cond do
      plan == current_plan ->
        Logger.info("RSMP: Already using plan: #{plan}")
        {
          {:ok, plan, "Already using plan #{plan}"},
          state
        }

      plan >= 0 && plan < 10 ->
        Logger.info("RSMP: Switching to plan: #{plan}")
        state = %{state | statuses: Map.put(state.statuses, path, plan)}
        {
          {:ok, plan, ""},
          state
        }

      true ->
        Logger.info("RSMP: Unknown plan: #{plan}")
        {
          {:unknown, plan, "Plan #{plan} not found"},
          state
        }
    end

    if plan != current_plan do
      properties = %{
        "Correlation-Data": command_id
      }

      {:ok, _pkt_id} =
        :emqtt.publish(
          # Client
          state[:pid],
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

      publish_status(state, path)

      data = %{topic: "status", changes: %{path => plan}}
      Phoenix.PubSub.broadcast(Rsmp.PubSub, "rsmp", data)
    end

    state
  end

  defp handle_publish(_, _, state) do
    {:noreply, state}
  end

  defp parse_topic(%{topic: topic}) do
    String.split(topic, "/", trim: true)
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
