defmodule Rsmp.Client do
  @moduledoc false

  # You can use this module from iex:
  # > Process.whereis(RSMP) |> RSMP.set_status("main","system",1,234)

  use GenServer
  require Logger

  defstruct(
      id: nil,
      pid: nil,
      statuses: %{},
      alarms: %{}
    )

  def new(options \\ %{}), do: __struct__(options)

  # api

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

  def get_alarms(pid) do
    GenServer.call(pid, :get_alarms)
  end

  def raise_alarm(pid, path) do
    GenServer.cast(pid, {:raise_alarm, path})
  end

  def clear_alarm(pid, path) do
    GenServer.cast(pid, {:clear_alarm, path})
  end

  def toggle_alarm_flag(pid, path, flag) do
    GenServer.cast(pid, {:toggle_alarm_flag, path, flag})
  end



  # genserver
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
        will_payload: to_payload(0),
        will_retain: true
      })

    Logger.info("RSMP: starting emqtt")
    {:ok, pid} = :emqtt.start_link(options)

    client = new(
      id: id,
      pid: pid,
      statuses: %{
        "main/system/temperature" => 21,
        "main/system/plan" => 1
      },
      alarms: %{
        "main/system/temperature" => %{
          "active" => true,
          "acknowledged" => false,
          "blocked" => false
        }
      }
    )

    {:ok, client, {:continue, :start_emqtt}}
  end

  def handle_continue(:start_emqtt, %{pid: pid, id: id}=client) do
    {:ok, _} = :emqtt.connect(pid)

    # subscribe to commands
    {:ok, _, _} = :emqtt.subscribe(pid, {"command/#{id}/plan", 1})

    publish_state(client,1)

    {:noreply, client}
  end

  # genserver api imlementation
  def handle_call(:get_id, _from, client) do
    {:reply, client.id, client}
  end

  def handle_call(:get_statuses, _from, client) do
    {:reply, client.statuses, client}
  end

  def handle_call({:get_status, path}, _from, client) do
    {:reply, client.statuses[path], client}
  end

  def handle_call(:get_alarms, _from, client) do
    {:reply, client.alarms, client}
  end


  def handle_cast({:set_status, path, value}, client) do
    client = %{client | statuses: Map.put(client.statuses, path, value)}
    publish_status(client, path)
    {:noreply, client}
  end

  def handle_cast({:raise_alarm, path}, client) do
    alarm = %{ client.alarms[path] | active: true}
    client = %{client | alarms: Map.put(client.alarms, path, alarm)}
    publish_alarm(client, path)
    {:noreply, client}
  end

  def handle_cast({:clear_alarm, path}, client) do
    alarm = %{}
    client = %{client | alarms: Map.put(client.alarms, path, alarm)}
    publish_alarm(client, path)
    {:noreply, client}
  end

  def handle_cast({:toggle_alarm_flag, path, flag}, client) do
    alarm = client.alarms[path]
    alarm = alarm |> Map.put(flag, alarm[flag] == false)
    client = %{client | alarms: Map.put(client.alarms, path, alarm)}
    publish_alarm(client, path)

      data = %{topic: "alarm", changes: %{path => path}}
      Phoenix.PubSub.broadcast(Rsmp.PubSub, "rsmp", data)

    {:noreply, client}
  end

  # mqtt
  def handle_info({:publish, publish}, client) do
    handle_publish(parse_topic(publish), publish, client)
  end

  defp handle_publish(
         ["command", _, "plan"],
         %{payload: payload, properties: properties},
         client
       ) do

    options = %{
      path: "main/system/plan",
      plan: from_payload(payload),
      response_topic: properties[:"Response-Topic"],
      command_id: properties[:"Correlation-Data"]
    }
    {:noreply, set_plan(client,options)}
  end

  defp handle_publish(_, _, client) do
    {:noreply, client}
  end

  defp parse_topic(%{topic: topic}) do
    String.split(topic, "/", trim: true)
  end

  # helpers
  defp publish_status(client, path) do
    :emqtt.publish(
      # Client
      client.pid,
      # Topic
      "status/#{client.id}/#{path}",
      # Properties
      %{},
      # Payload
      to_payload(client.statuses[path]),
      # Opts
      retain: true,
      qos: 1
    )
  end

  defp publish_alarm(client, path) do
    :emqtt.publish(
      # Client
      client.pid,
      # Topic
      "alarm/#{client.id}/#{path}",
      # Properties
      %{},
      # Payload
      to_payload(client.alarms[path]),
      # Opts
      retain: true,
      qos: 1
    )
  end

  defp set_plan(client,%{
      path: path,
      plan: plan,
      response_topic: response_topic,
      command_id: command_id
    }) do
    
    current_plan = client.statuses[path]

    {response,client} = cond do
      plan == current_plan ->
        Logger.info("RSMP: Already using plan: #{plan}")
        {
          %{status: "ok", plan: plan, reason: "Already using plan #{plan}"},
          client
        }

      plan >= 0 && plan < 10 ->
        Logger.info("RSMP: Switching to plan: #{plan}")
        client = %{client | statuses: Map.put(client.statuses, path, plan)}
        {
          %{status: "ok", plan: plan, reason: ""},
          client
        }

      true ->
        Logger.info("RSMP: Unknown plan: #{plan}")
        {
          %{status: "unknown", plan: plan, reason: "Plan #{plan} not found"},
          client
        }
    end

    if plan != current_plan do

      if response_topic do
        properties = %{
          "Correlation-Data": command_id
        }

        {:ok, _pkt_id} =
          :emqtt.publish(
            # Client
            client.pid,
            # Topic
            response_topic,
            # Properties
            properties,
            # Payload
            to_payload(response),
            # Opts
            retain: false,
            qos: 2
          )
      end

      publish_status(client, path)

      data = %{topic: "status", changes: %{path => plan}}
      Phoenix.PubSub.broadcast(Rsmp.PubSub, "rsmp", data)
    end

    client
  end

  defp publish_state(client,state) do
    :emqtt.publish(
      client.pid,
      "state/#{client.id}",
      to_payload(state),
      retain: true
    )
  end

  def to_payload(data) do
    {:ok, json} = JSON.encode(data)
    #Logger.info "Encoded #{data} to JSON: #{inspect(json)}"
    json
  end

  def from_payload(json) do
    try do
      {:ok, data} = JSON.decode(json)
      #Logger.info "Decoded JSON #{json} to #{data}"
      data
    rescue
      _e ->
      #Logger.warning "Could not decode JSON: #{inspect(json)}"
      nil
    end
  end
end
