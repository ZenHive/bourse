defmodule Bourse.Application do
  @moduledoc """
  OTP Application for Bourse.

  Starts the rate limiter, rate limit state store, native signer supervisor,
  WS broadcast registry, and WS connection-owner supervisor, and installs
  `Bourse.LogRedaction`'s primary `:logger` filter unless
  `config :bourse, :redact_termination_reports, false` (see that module).

  `Bourse.Testnet` is deliberately NOT a child here. It is a sandbox credential
  registry that only test and recording harnesses use, so a consumer application
  must not pay for it at boot; callers that need it start it explicitly.
  """

  use Application

  alias Bourse.WS.Broadcast

  require Logger

  @impl true
  def start(_type, _args) do
    if Application.get_env(:bourse, :redact_termination_reports, true) do
      with {:error, reason} <- Bourse.LogRedaction.install() do
        Logger.warning("Bourse.LogRedaction not installed: #{inspect(reason)}")
      end
    end

    children = [
      Bourse.RateLimiter,
      Bourse.RateLimiter.State,
      Bourse.Signing.Lighter.Supervisor,
      Broadcast.child_spec(),
      Bourse.WS.ConnectionOwner.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Bourse.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state), do: Bourse.LogRedaction.uninstall()
end
