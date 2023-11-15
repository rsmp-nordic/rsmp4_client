defmodule Rsmp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      RsmpWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Rsmp.PubSub},
      # Start Finch
      {Finch, name: Rsmp.Finch},
      # Start the Endpoint (http/https)
      RsmpWeb.Endpoint,
      # Start a worker by calling: Rsmp.Worker.start_link(arg)
      # {Rsmp.Worker, arg}
      # Start our RSMP supervisor
      RsmpSupervisor
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Rsmp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RsmpWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
