defmodule Bourse.Application do
  @moduledoc """
  OTP Application for Bourse.

  Starts the rate limiter, rate limit state store, native signer supervisor and
  WS broadcast registry under supervision.

  `Bourse.Testnet` is deliberately NOT a child here. It is a sandbox credential
  registry that only test and recording harnesses use, so a consumer application
  must not pay for it at boot; callers that need it start it explicitly.
  """

  use Application

  alias Bourse.WS.Broadcast

  @impl true
  def start(_type, _args) do
    children = [
      Bourse.RateLimiter,
      Bourse.RateLimiter.State,
      Bourse.Signing.Lighter.Supervisor,
      Broadcast.child_spec()
    ]

    opts = [strategy: :one_for_one, name: Bourse.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
