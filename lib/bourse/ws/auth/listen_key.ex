defmodule Bourse.WS.Auth.ListenKey do
  @moduledoc """
  Listen Key auth pattern — binance family, aster.

  `pre_auth/3` resolves the correct REST endpoint for the current market
  type from `config[:pre_auth][:endpoints]`. The actual REST call, listen
  key extraction, WS URL embedding, and periodic refresh all happen in the
  adapter layer (T94/T95) — this module is pure endpoint resolution so it
  stays network-free and unit-testable.

  ## Pre-auth Endpoints by Market Type

  | Market | Endpoint |
  |---|---|
  | Linear (USD-M) | `fapiPrivatePostListenKey` |
  | Inverse (COIN-M) | `dapiPrivatePostListenKey` |
  | Spot | `publicPostUserDataStream` |
  | Margin | `sapiPostUserDataStream` |
  | Isolated margin | `sapiPostUserDataStreamIsolated` |
  | Portfolio margin | `papiPostListenKey` |

  ## Config / opts

      config = %{
        pre_auth: %{
          endpoints: [
            %{type: :spot, endpoint: "publicPostUserDataStream", ...},
            %{type: :linear, endpoint: "fapiPrivatePostListenKey", ...}
          ]
        }
      }

      opts[:market_type]  # :spot | :linear | :inverse | :margin | ...
                          # :future and :delivery are normalized to :linear/:inverse

  ## Returns from `pre_auth/3`

      {:ok, %{endpoint:, market_type:, api_section:, method:, path:, credentials:}}
      | {:error, {:no_endpoint_for_market_type, %{requested:, normalized:, available:}}}
  """

  @behaviour Bourse.WS.Auth.Behaviour

  @impl true
  def pre_auth(credentials, config, opts) do
    raw_type = opts[:market_type] || :spot
    market_type = normalize_market_type(raw_type)
    endpoints = normalize_endpoints(get_in(config, [:pre_auth, :endpoints]) || [])

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
           market_type: market_type,
           api_section: endpoint[:api_section],
           # Listen key endpoints are POST by convention.
           method: endpoint[:method] || "POST",
           path: endpoint[:path],
           credentials: credentials
         }}
    end
  end

  # The authored specs carry the endpoints as `%{market_type => endpoint_name}`,
  # while this module's own documented shape is a list of maps. Iterating the
  # authored map yields `{key, value}` tuples, and `ep.type` on a tuple raises
  # BadMapError — so the binance family used to crash here instead of reporting
  # the REST round-trip it needs. Both shapes normalize to the list form.
  defp normalize_endpoints(endpoints) when is_list(endpoints), do: endpoints

  defp normalize_endpoints(endpoints) when is_map(endpoints) do
    Enum.map(endpoints, fn {type, endpoint} when is_binary(endpoint) ->
      %{type: type, endpoint: endpoint}
    end)
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
