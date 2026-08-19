defmodule Bourse.WS.Auth.ListenKey do
  @moduledoc """
  Listen key auth pattern — binance USD-M and COIN-M futures.

  The credential is not a frame: the venue issues a listen key over REST and
  the key travels in the WebSocket URL. USD-M uses query parameters while
  COIN-M uses a path segment. `pre_auth/3` resolves which endpoint issues and
  which refreshes it for the requested market type;
  `Bourse.WS.ListenKey` performs the calls and `Bourse.WS.connect/3` embeds the
  result. This module stays network-free so endpoint resolution can be tested
  without a venue.

  ## Scope — binance spot is not a listen key venue any more

  Binance removed the spot and margin listen key endpoints on 2026-02-20; a
  `POST /api/v3/userDataStream` now answers HTTP 410 Gone (observed on
  `testnet.binance.vision` 2026-08-06). Spot's user data stream is opened over
  the WebSocket API instead — see `Bourse.WS.Auth.WsApiSignature`. Only the
  futures endpoints below still issue keys.

  ## Config

      auth_config = %{
        pre_auth: %{
          type: :listen_key,
          default_market_type: :linear,
          endpoints: %{linear: :fapiPrivate_post_listenkey},
          keepalive_endpoints: %{linear: :fapiPrivate_put_listenkey},
          keepalive_ms: 1_800_000
        }
      }

  `endpoints` values are generated raw endpoint names — the same atoms
  `__endpoints__/0` reports on the exchange module — so the resolved endpoint
  is dispatchable rather than a name that has to be translated first.

  `opts[:market_type]` selects the entry (`:future`/`:delivery`/`:contract`
  normalize to `:linear`/`:inverse`). Without it the venue's
  `default_market_type` applies, because the market type a venue's private
  stream covers is the venue's fact, not the caller's choice — binanceusdm has
  only linear markets and would otherwise resolve a spot endpoint it does not
  serve.

  ## Returns from `pre_auth/3`

      {:ok, %{endpoint:, keepalive_endpoint:, market_type:, keepalive_ms:, credentials:}}
      | {:error, {:no_endpoint_for_market_type, %{requested:, normalized:, available:}}}
  """

  @behaviour Bourse.WS.Auth.Behaviour

  # Binance expires an idle listen key 60 minutes after it is issued and
  # documents a keepalive every 30. Used when a venue authors no interval.
  @default_keepalive_ms 1_800_000

  @impl true
  def pre_auth(credentials, config, opts) do
    pre_auth_config = get_in(config, [:pre_auth]) || %{}
    raw_type = opts[:market_type] || pre_auth_config[:default_market_type] || :spot
    market_type = normalize_market_type(raw_type)
    endpoints = normalize_endpoints(pre_auth_config[:endpoints] || [])

    case Enum.find(endpoints, fn ep -> ep.type == market_type end) do
      nil ->
        {:error,
         {:no_endpoint_for_market_type,
          %{
            requested: raw_type,
            normalized: market_type,
            available: Enum.map(endpoints, & &1.type)
          }}}

      endpoint ->
        {:ok,
         %{
           endpoint: endpoint.endpoint,
           keepalive_endpoint: keepalive_endpoint(pre_auth_config, market_type),
           market_type: market_type,
           keepalive_ms: pre_auth_config[:keepalive_ms] || @default_keepalive_ms,
           credentials: credentials
         }}
    end
  end

  defp keepalive_endpoint(pre_auth_config, market_type) do
    pre_auth_config
    |> Map.get(:keepalive_endpoints, %{})
    |> normalize_endpoints()
    |> Enum.find_value(fn ep -> if ep.type == market_type, do: ep.endpoint end)
  end

  # The authored configs carry the endpoints as `%{market_type => endpoint}`,
  # while this module's own documented shape is a list of maps. Iterating the
  # authored map yields `{key, value}` tuples, and `ep.type` on a tuple raises
  # BadMapError — so the binance family used to crash here instead of reporting
  # the REST round-trip it needs. Both shapes normalize to the list form.
  defp normalize_endpoints(endpoints) when is_list(endpoints), do: endpoints

  defp normalize_endpoints(endpoints) when is_map(endpoints) do
    Enum.map(endpoints, fn {type, endpoint} -> %{type: type, endpoint: endpoint} end)
  end

  # WS URL paths use :future/:delivery; listen key endpoints use :linear/:inverse.
  defp normalize_market_type(:future), do: :linear
  defp normalize_market_type(:delivery), do: :inverse
  defp normalize_market_type(:contract), do: :linear
  defp normalize_market_type(other), do: other

  @impl true
  def build_auth_message(_credentials, _config, _opts), do: :no_message

  @impl true
  def handle_auth_response(_response, _state), do: :ok
end
