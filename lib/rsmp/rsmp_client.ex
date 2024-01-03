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

  def new(options), do: __struct__(options)

  # api
  def start_link(_options \\ []) do
    {:ok, pid} = GenServer.start_link(__MODULE__, [])
    Logger.info("RSMP: Start client with pid #{inspect(pid)}")
    {:ok, pid}
  end

  def get_id(pid) do
    GenServer.call(pid, :get_id)
  end

  def get_statuses(pid) do
    GenServer.call(pid, :get_statuses)
  end

  def get_status(pid, path) do
    GenServer.call(pid, {:get_status, path})
  end

  def get_alarms(pid) do
    GenServer.call(pid, :get_alarms)
  end

  def get_alarm_flag(pid, path, flag) do
    GenServer.call(pid, {:get_alarm_flag, path, flag})
  end


  def set_status(pid, path, value) do
    GenServer.cast(pid, {:set_status, path, value})
  end

  def raise_alarm(pid, path) do
    GenServer.cast(pid, {:raise_alarm, path})
  end

  def clear_alarm(pid, path) do
    GenServer.cast(pid, {:clear_alarm, path})
  end

  def set_alarm_flag(pid, path, flag, value) do
    GenServer.cast(pid, {:set_alarm_flag, path, flag, value})
  end

  def toggle_alarm_flag(pid, path, flag) do
    GenServer.cast(pid, {:toggle_alarm_flag, path, flag})
  end


  # genserver
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
        "main/system/plan" => 1,
        "main/system/temperature" => 28,
        "main/system/humidity" => 48,
      }
    )
    |> reset_alarm("main/system/temperature")
    |> reset_alarm("main/system/humidity")

    {:ok, client, {:continue, :start_emqtt}}
  end

  def handle_continue(:start_emqtt, %{pid: pid, id: id}=client) do
    {:ok, _} = :emqtt.connect(pid)

    # subscribe to commands
    {:ok, _, _} = :emqtt.subscribe(pid, {"command/#{id}/plan", 1})

    # subscribe to alarm flag requests
    {:ok, _, _} = :emqtt.subscribe(pid, {"flag/#{id}/#", 1})

    publish_state(client,1)
    publish_all(client)
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

  def handle_call({:get_alarm_flag, path, flag}, _from, client) do
    alarm = client.alarms[path] || %{}
    flag = alarm[flag] || false
    {:reply, flag, client}
  end


  def handle_cast({:set_status, path, value}, client) do
    client = %{client | statuses: Map.put(client.statuses, path, value)}
    publish_status(client, path)
    {:noreply, client}
  end

  def handle_cast({:raise_alarm, path}, client) do
    if client.alarms[path]["active"] == false do
      client = put_in(client.alarms[path]["active"], true)
      publish_alarm(client, path)

      data = %{topic: "alarm", changes: %{path => path}}
      Phoenix.PubSub.broadcast(Rsmp.PubSub, "rsmp", data)
      {:noreply, client}
    else
      {:noreply, client}
    end
  end

  def handle_cast({:clear_alarm, path}, client) do
    if client.alarms[path]["active"] == true do
      client = put_in(client.alarms[path]["active"], false)
      publish_alarm(client, path)

      data = %{topic: "alarm", changes: %{path => path}}
      Phoenix.PubSub.broadcast(Rsmp.PubSub, "rsmp", data)
      {:noreply, client}
    else
      {:noreply, client}
    end
    
  end

  def handle_cast({:set_alarm_flag, path, flag, value}, client) do
    if client.alarms[path][flag] != value do
      client = put_in(client.alarms[path][flag], value)
      publish_alarm(client, path)

      data = %{topic: "alarm", changes: %{path => path}}
      Phoenix.PubSub.broadcast(Rsmp.PubSub, "rsmp", data)
      {:noreply, client}
    else
      {:noreply, client}
    end
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

  def handle_info({:disconnected, code, _publish}, client) do
    Logger.warning "RSMP: Disconnected, code: #{code}"
    #handle_disconnect(parse_topic(publish), publish, client)
    {:noreply, client}
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

  defp handle_publish(
         ["flag", _, component, module, code],
         %{payload: payload, properties: _properties},
         client
       ) do

    flags = from_payload(payload)
    path = "#{component}/#{module}/#{code}"

    Logger.info("RSMP: Received alarm flag #{path}, #{inspect(flags)}")

    alarm = client.alarms[path] |> Map.merge(flags)
    client = put_in(client.alarms[path], alarm)

    publish_alarm(client, path)

    data = %{topic: "alarm", changes: %{path => client.alarms[path]}}
    Phoenix.PubSub.broadcast(Rsmp.PubSub, "rsmp", data)

    {:noreply,client}
  end


  defp handle_publish(topic, _, client) do
    Logger.warning "Unhandled publish: #{inspect(topic)}"
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

  defp alarm_flag_string(client,path) do
    client.alarms[path]
    |> Enum.filter( fn {_flag,value} -> value == true end)
    |> Enum.map( fn {flag,_value} -> flag end)
    |> inspect()
  end

  defp publish_alarm(client, path) do
    flags = alarm_flag_string(client,path)
    Logger.info("RSMP: Sending alarm: #{path} #{flags}")
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

  defp reset_alarm(client,path) do
    put_in(client.alarms[path],%{
      "active" => false,
      "acknowledged" => false,
      "blocked" => false
    })
  end

  defp publish_all(client) do
    for path <- Map.keys(client.alarms), do: publish_alarm(client, path)
    for path <- Map.keys(client.statuses), do: publish_status(client, path)    
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
          %{status: "already", plan: plan, reason: "Already using plan #{plan}"},
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

    if response[:status] == "ok"do
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