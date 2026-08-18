defmodule Bourse.WS.Config do
  @moduledoc """
  Per-exchange WebSocket configuration.

  Effective config merges v4.1.0 `websocket.*` spec slices (heartbeat, auth,
  urls when emitted) with hand-maintained bases in `Bourse.WS.SpecConfig` for
  subscription patterns, URL fallbacks, and auth pattern detail.

  Ten runtime venues have hand bases. Coinbase Exchange is the sole registered
  runtime/config divergence because its WebSocket transport is not configured.
  Spec-resolved heartbeat/auth overrides hand values where
  `unresolved_reason` is nil.

  ## Entry shape

      %{
        public_url: String.t() | nil,
        public_url_sandbox: String.t() | nil,
        market_url: String.t() | nil,
        market_url_sandbox: String.t() | nil,
        private_url: String.t() | nil,
        private_url_sandbox: String.t() | nil,
        heartbeat: %{type: :ping | :deribit | :custom, interval: pos_integer() | nil, optional(:payload) => term()},
        subscription_pattern: atom(),
        subscription_config: map(),
        auth_pattern: atom() | nil,
        auth_config: map(),
        optional(:auth_sections) => [:public | :private]
      }

  See `Bourse.WS.SpecConfig` for hand-base details and known URL limitations.
  """

  alias Bourse.Exchange
  alias Bourse.WS.SpecConfig

  @registered_divergences %{"coinbaseexchange" => :websocket_not_configured}

  @doc """
  Returns the WS config map for the given exchange id or struct, or nil if it
  has no configured WebSocket transport.

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

  @doc "Returns runtime exchanges intentionally lacking a WS config and the reason for each gap."
  @spec registered_divergences() :: %{String.t() => :websocket_not_configured}
  def registered_divergences, do: @registered_divergences

  @doc """
  Error for a missing WS config.

  A runtime-supported venue without a hand base is `:websocket_not_configured`.
  A venue outside runtime support is `:unsupported_exchange`.
  """
  @spec missing_config_error(String.t()) ::
          {:error, :websocket_not_configured | :unsupported_exchange}
  def missing_config_error(exchange_id) when is_binary(exchange_id) do
    if exchange_id in Bourse.Spec.exchanges() do
      {:error, :websocket_not_configured}
    else
      {:error, :unsupported_exchange}
    end
  end
end
