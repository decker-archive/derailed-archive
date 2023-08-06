defmodule Derailed.Utils.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Postgrex, Application.fetch_env!(:derailed, :db)},
      {Task.Supervisor, name: Derailed.Tasks}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Derailed.Utils.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
