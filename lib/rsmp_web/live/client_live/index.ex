defmodule RsmpWeb.ClientLive.Index do
  use RsmpWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,pid} = RsmpClient.start_link([])
    {:ok,socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_status", %{"state" => status_str}, socket) do
    case Integer.parse(status_str) do
      {status, ""} ->
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
