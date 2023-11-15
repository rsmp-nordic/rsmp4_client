defmodule RsmpClient do
  @moduledoc false

  use GenServer

  require Logger

  def start_link([]) do
    {:ok, pid} = GenServer.start_link(__MODULE__, [])
    Logger.info("Starting RSMP client with pid #{inspect(pid)}")

    {:ok, pid}
  end

  def init([]) do
    interval = Application.get_env(:rsmp, :interval)
    emqtt_opts = Application.get_env(:rsmp, :emqtt)
    id = emqtt_opts[:clientid]

    options =
      emqtt_opts ++
        [
          will_topic: "state/#{id}",
          will_payload: :erlang.term_to_binary(0),
          will_retain: true
        ]

    {:ok, pid} = :emqtt.start_link(options)

    state = %{
      id: id,
      pid: pid,
      interval: interval,
      timer: nil,
      status: %{1 => 0},
      plan: 1
    }

    {:ok, set_timer(state), {:continue, :start_emqtt}}
  end

  def handle_continue(:start_emqtt, %{pid: pid} = state) do
    {:ok, _} = :emqtt.connect(pid)
    emqtt_opts = Application.get_env(:rsmp, :emqtt)
    clientid = emqtt_opts[:clientid]

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
    new_state = %{state | plan: String.to_integer(payload)}

    pid = state[:pid]
    response_topic = properties[:"Response-Topic"]
    command_id = properties[:"Correlation-Data"]

    Logger.info(
      "Received '#{command}' command #{command_id}: Switching to plan: #{new_state[:plan]}"
    )

    if response_topic && command_id do
      response_message = :ok
      response_payload = :erlang.term_to_binary(response_message)

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
          response_payload,
          # Opts
          retain: false,
          qos: 1
        )
    end

    # {:noreply, set_timer(new_state)}
    {:noreply, new_state}
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
  def set_status(pid, component, module, code, value) do
    GenServer.call(pid, {:set_status, component, module, code, value})
  end

  def send_all_status(pid) do
    GenServer.call(pid, {:send_all_status})
  end

  # server
  def handle_call({:set_status, component, module, code, value}, _from, state) do
    path = "#{component}/#{module}/#{code}"
    state = %{state | status: Map.put(state.status, path, value)}
    publish_status(state, component, module, code)
    {:reply, :ok, state}
  end

  def handle_call({:send_all_status}, _from, state) do
    publish_all_status(state)
    {:reply, :ok, state}
  end

  # internal
  defp publish_status(state, component, module, code) do
    path = "#{component}/#{module}/#{code}"

    :emqtt.publish(
      # Client
      state.pid,
      # Topic
      "status/#{state.id}/#{path}",
      # Properties
      %{},
      # Payload
      :erlang.term_to_binary(state.status[path]),
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
