defmodule RsmpWeb.ClientLive.Index do
  use RsmpWeb, :live_view

  require Logger

  @impl true
  def mount(params, session, socket) do
    case connected?(socket) do
      true -> connected_mount(params, session, socket)
      false -> {:ok, assign(socket, page: "loading", id: "")}
    end
  end

  def connected_mount(_params, _session, socket) do
    {:ok,pid} = RsmpClient.start_link([])
    {:ok, assign(socket, rsmp_client_id: pid, id: RsmpClient.get_id(pid))}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_status", %{"state" => status_str}, socket) do
    case Integer.parse(status_str) do
      {_status, ""} ->
        {:noreply, socket}

      _ ->
        {:noreply, socket}
      
    end
  end

  def handle_event(name, data, socket) do
    Logger.info("handle_event: #{inspect([name, data])}")
    {:noreply, socket}
  end
end
