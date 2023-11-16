defmodule RsmpWeb.ClientLive.Index do
  use RsmpWeb, :live_view

  require Logger

  @impl true
  def mount(params, session, socket) do
    case connected?(socket) do
      true ->
        connected_mount(params, session, socket)

      false ->
        {:ok,
         assign(socket,
           page: "loading",
           id: "",
           statuses: %{}
         )}
    end
  end

  def connected_mount(_params, _session, socket) do
    {:ok, pid} = RsmpClient.start_link([])

    {:ok,
     assign(socket,
       rsmp_client_id: pid,
       id: RsmpClient.get_id(pid),
       statuses: RsmpClient.get_statuses(pid)
     )}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def change_status(data, socket, delta) do
    path = data["value"]
    pid = socket.assigns[:rsmp_client_id]
    statuses = RsmpClient.get_statuses(pid)
    new_value = statuses[path] + delta
    RsmpClient.set_status(pid, path, new_value)
    statuses = RsmpClient.get_statuses(pid)
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

  def handle_event(name, data, socket) do
    Logger.info("handle_event: #{inspect([name, data])}")
    {:noreply, socket}
  end
end
