defmodule Bourse.WS.URLRouting do
  @moduledoc """
  Pure URL resolution for WebSocket endpoints.

  Given a `%Bourse.Exchange{}`, returns the public or private WS URL appropriate
  for the current sandbox flag, with `{hostname}` interpolated from
  `exchange.hostname`.

  URLs come from `Bourse.WS.Config`, which prefers resolved `websocket.urls`
  from the spec and falls back to hand-maintained bases when absent.
  """

  alias Bourse.Exchange
  alias Bourse.WS.Config
  alias Bourse.WS.Helpers

  @doc """
  Public WS URL for the given exchange, or nil if the exchange has no WS config.

  Honors `exchange.sandbox` — returns the sandbox URL when the flag is true
  and a sandbox URL is configured.
  """
  @spec public_url(Exchange.t()) :: String.t() | nil
  def public_url(%Exchange{} = exchange) do
    resolve(exchange, :public)
  end

  @doc """
  Private WS URL for the given exchange, or nil if the exchange has no WS config
  or no private endpoint.
  """
  @spec private_url(Exchange.t()) :: String.t() | nil
  def private_url(%Exchange{} = exchange) do
    resolve(exchange, :private)
  end

  defp resolve(%Exchange{} = exchange, section) do
    %{sandbox: sandbox, hostname: hostname} = exchange

    case Config.for_exchange(exchange) do
      nil ->
        nil

      config ->
        config
        |> pick_url(section, sandbox)
        |> Helpers.interpolate_hostname(hostname)
    end
  end

  defp pick_url(config, :public, true), do: config[:public_url_sandbox] || config[:public_url]
  defp pick_url(config, :public, false), do: config[:public_url]
  defp pick_url(config, :private, true), do: config[:private_url_sandbox] || config[:private_url]
  defp pick_url(config, :private, false), do: config[:private_url]
end
