defmodule Bourse.WS.Config do
  @moduledoc """
  Per-exchange WebSocket configuration.

  Effective config merges v4.1.0 `websocket.*` spec slices (heartbeat, auth,
  urls when emitted) with hand-maintained bases in `Bourse.WS.SpecConfig` for
  subscription patterns, URL fallbacks, and auth pattern detail.

  Seven runtime venues currently have hand bases: `binance`, `binanceusdm`,
  `bybit`, `deribit`, `derive`, `hyperliquid`, and `okx`. Spec-resolved
  heartbeat/auth overrides hand values where `unresolved_reason` is nil.

  ## Entry shape

      %{
        public_url: String.t() | nil,
        public_url_sandbox: String.t() | nil,
        private_url: String.t() | nil,
        private_url_sandbox: String.t() | nil,
        heartbeat: %{type: :ping | :deribit | :custom, interval: pos_integer() | nil, optional(:payload) => term()},
        subscription_pattern: atom(),
        subscription_config: map(),
        auth_pattern: atom() | nil,
        auth_config: map()
      }

  See `Bourse.WS.SpecConfig` for hand-base details and known URL limitations.
  """

  alias Bourse.Exchange
  alias Bourse.WS.SpecConfig

  @doc """
  Returns the WS config map for the given exchange id or struct, or nil if unsupported.

  When passed a `%Bourse.Exchange{}`, merges using the lean `exchange.spec`.
  """
  @spec for_exchange(String.t() | Exchange.t()) :: map() | nil
  def for_exchange(id) when is_binary(id), do: SpecConfig.build(id)
  def for_exchange(%Exchange{} = exchange), do: SpecConfig.build(exchange)

  @doc "Returns true if this exchange has a WS config entry."
  @spec supported?(String.t()) :: boolean()
  def supported?(id) when is_binary(id), do: for_exchange(id) != nil

  @doc "Returns all supported exchange ids."
  @spec supported_exchanges() :: [String.t()]
  def supported_exchanges, do: SpecConfig.hand_bases() |> Map.keys() |> Enum.sort()
end
