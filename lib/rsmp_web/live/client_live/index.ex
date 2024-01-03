defmodule RSMPWeb.ClientLive.Index do
  use RSMPWeb, :live_view

  require Logger

  @impl true
  def mount(params, session, socket) do
    case connected?(socket) do
      false ->
        initial_mount(params, session, socket)

      true ->
        connected_mount(params, session, socket)
    end
  end

  def initial_mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page: "loading",
       id: "",
       statuses: %{},
       alarms: %{},
       alarm_flags: Enum.sort(["active", "acknowledged", "blocked"])
     )}
  end

  def connected_mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "rsmp")
    {:ok, pid} = RSMP.Client.start_link([])

    {:ok,
     assign(socket,
       rsmp_client_id: pid,
       id: RSMP.Client.get_id(pid),
       statuses: RSMP.Client.get_statuses(pid),
       alarms: RSMP.Client.get_alarms(pid),
       alarm_flags: Enum.sort(["active", "acknowledged", "blocked"])
     )}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def change_status(data, socket, delta) do
    path = data["value"]
    pid = socket.assigns[:rsmp_client_id]
    statuses = RSMP.Client.get_statuses(pid)
    new_value = statuses[path] + delta
    RSMP.Client.set_status(pid, path, new_value)


    if path == "main/system/temperature" do
      if new_value >= 30 do
        RSMP.Client.raise_alarm(pid, path)
      else
        RSMP.Client.clear_alarm(pid, path)
      end
    end

    if path == "main/system/humidity" do
      if new_value >= 50 do
        RSMP.Client.raise_alarm(pid, path)
      else
        RSMP.Client.clear_alarm(pid, path)
      end
    end

    
    statuses = RSMP.Client.get_statuses(pid)
    {:noreply, assign(socket, statuses: statuses)}
  end

  @impl true
  def handle_event("increase", data, socket) do
    change_status(data, socket, 1)
  end

  @impl true
  def handle_event("decrease", data, socket) do
    change_status(data, socket, -1)
  end

  @impl true
  def handle_event("alarm", %{"path" => path, "value" => flag}=_data, socket) do
    pid = socket.assigns[:rsmp_client_id]
    RSMP.Client.toggle_alarm_flag(pid,path,flag)
    {:noreply, socket}
  end

  @impl true
  def handle_event(_name, _data, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: "status", changes: _changes}, socket) do
    pid = socket.assigns[:rsmp_client_id]
    statuses = RSMP.Client.get_statuses(pid)
    {:noreply, assign(socket, statuses: statuses)}
  end

  @impl true
  def handle_info(%{topic: "alarm", changes: _changes}, socket) do
    pid = socket.assigns[:rsmp_client_id]
    alarms = RSMP.Client.get_alarms(pid)
    {:noreply, assign(socket, alarms: alarms)}
  end


end
