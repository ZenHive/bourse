defmodule Bourse.WS.SpecConfig do
  @moduledoc """
  Merges v4.1.0 `websocket.*` spec slices with hand-maintained WS overrides.

  Resolved spec fields win; unresolved or absent fields fall back to hand
  config without guessing. Subscription channel templates remain T97-owned.
  """

  alias Bourse.Exchange
  alias Bourse.Spec

  @public_heartbeat_interval_ms 30_000

  @doc """
  Builds the effective WS config map for an exchange, or nil when unsupported.

  `hand` carries subscription patterns and hand-only URL/auth detail; spec slices
  override heartbeat and auth pattern selection when resolved.
  """
  @spec build(String.t()) :: map() | nil
  def build(exchange_id) when is_binary(exchange_id) do
    build(exchange_id, load_spec(exchange_id), Map.get(hand_bases(), exchange_id))
  end

  @spec build(Exchange.t()) :: map() | nil
  def build(%Exchange{id: id, spec: spec}) do
    build(id, spec, Map.get(hand_bases(), id))
  end

  @spec build(String.t(), map() | nil, map() | nil) :: map() | nil
  def build(_exchange_id, _spec, nil), do: nil

  def build(exchange_id, spec, hand) do
    hand
    |> merge_urls(exchange_id, spec)
    |> merge_heartbeat(exchange_id, spec)
    |> merge_auth(exchange_id, spec)
  end

  # ---------------------------------------------------------------------------
  # Hand bases — subscription patterns + slices spec does not yet resolve.
  # ---------------------------------------------------------------------------

  @hand_bases %{
    "alpaca" => %{
      public_url: "wss://stream.data.alpaca.markets/v2/iex",
      public_url_sandbox: "wss://stream.data.alpaca.markets/v2/test",
      private_url: nil,
      private_url_sandbox: nil,
      heartbeat: %{type: :ping, interval: @public_heartbeat_interval_ms},
      subscription_pattern: :action_channels,
      subscription_config: %{},
      auth_pattern: :action_key_secret,
      auth_config: %{},
      auth_sections: [:public]
    },
    "binance" => %{
      public_url: "wss://stream.binance.com:9443/ws",
      public_url_sandbox: "wss://stream.testnet.binance.vision/ws",
      # Spot's private stream is not on the market-stream host. Binance retired
      # the spot listen key on 2026-02-20 — `POST /api/v3/userDataStream` now
      # answers HTTP 410 — and the user data stream moved to the WebSocket API
      # host, opened by a signed request rather than by a key in the path.
      private_url: "wss://ws-api.binance.com:443/ws-api/v3",
      private_url_sandbox: "wss://ws-api.testnet.binance.vision/ws-api/v3",
      heartbeat: %{type: :ping, interval: 180_000},
      subscription_pattern: :method_subscribe,
      subscription_config: %{separator: "@", market_id_format: :lowercase},
      auth_pattern: :ws_api_signature,
      auth_config: %{method: "userDataStream.subscribe.signature"}
    },
    "binanceusdm" => %{
      public_url: "wss://fstream.binance.com/public/ws",
      public_url_sandbox: "wss://demo-fstream.binance.com/public/ws",
      market_url: "wss://fstream.binance.com/market/ws",
      market_url_sandbox: "wss://demo-fstream.binance.com/market/ws",
      private_url: "wss://fstream.binance.com/private/ws",
      private_url_sandbox: "wss://demo-fstream.binance.com/private/ws",
      heartbeat: %{type: :ping, interval: 180_000},
      subscription_pattern: :method_subscribe,
      subscription_config: %{separator: "@", market_id_format: :lowercase},
      auth_pattern: :listen_key,
      auth_config: %{
        listen_key_url: %{
          placement: :query,
          events: ["ORDER_TRADE_UPDATE", "ACCOUNT_UPDATE"]
        },
        pre_auth: %{
          type: :listen_key,
          # binanceusdm trades linear markets only, so a caller that names no
          # market type must not fall through to a spot endpoint the venue
          # does not serve.
          default_market_type: :linear,
          endpoints: %{linear: :fapiPrivate_post_listenkey},
          keepalive_endpoints: %{linear: :fapiPrivate_put_listenkey},
          # Binance expires an idle key after 60 minutes and documents a
          # 30-minute refresh.
          keepalive_ms: 1_800_000
        }
      }
    },
    "binancecoinm" => %{
      public_url: "wss://dstream.binance.com/ws",
      public_url_sandbox: "wss://demo-dstream.binance.com/ws",
      private_url: "wss://dstream.binance.com/ws",
      private_url_sandbox: "wss://demo-dstream.binance.com/ws",
      heartbeat: %{type: :ping, interval: 180_000},
      subscription_pattern: :method_subscribe,
      subscription_config: %{separator: "@", market_id_format: :lowercase},
      auth_pattern: :listen_key,
      auth_config: %{
        listen_key_url: %{placement: :path},
        pre_auth: %{
          type: :listen_key,
          # COIN-M is the inverse half of the one demo futures account; its
          # wallet and its listen key are separate from USD-M's.
          default_market_type: :inverse,
          endpoints: %{inverse: :dapiPrivate_post_listenkey},
          keepalive_endpoints: %{inverse: :dapiPrivate_put_listenkey},
          keepalive_ms: 1_800_000
        }
      }
    },
    "bybit" => %{
      public_url: "wss://stream.{hostname}/v5/public/linear",
      public_url_sandbox: "wss://stream-testnet.{hostname}/v5/public/linear",
      private_url: "wss://stream.{hostname}/v5/private",
      private_url_sandbox: "wss://stream-testnet.{hostname}/v5/private",
      heartbeat: %{type: :ping, interval: 20_000},
      subscription_pattern: :op_subscribe,
      subscription_config: %{separator: "."},
      auth_pattern: :direct_hmac_expiry,
      auth_config: %{
        op_field: "op",
        op_value: "auth",
        encoding: :hex,
        expires_offset_ms: 10_000
      }
    },
    "okx" => %{
      public_url: "wss://ws.okx.com:8443/ws/v5/public",
      public_url_sandbox: "wss://wspap.okx.com:8443/ws/v5/public",
      private_url: "wss://ws.okx.com:8443/ws/v5/private",
      private_url_sandbox: "wss://wspap.okx.com:8443/ws/v5/private",
      heartbeat: %{type: :ping, interval: 25_000},
      subscription_pattern: :op_subscribe_objects,
      subscription_config: %{},
      auth_pattern: :iso_passphrase,
      auth_config: %{timestamp_unit: :seconds}
    },
    "deribit" => %{
      public_url: "wss://www.deribit.com/ws/api/v2",
      public_url_sandbox: "wss://test.deribit.com/ws/api/v2",
      private_url: "wss://www.deribit.com/ws/api/v2",
      private_url_sandbox: "wss://test.deribit.com/ws/api/v2",
      heartbeat: %{type: :deribit, interval: 30_000},
      subscription_pattern: :jsonrpc_subscribe,
      subscription_config: %{method: "public/subscribe"},
      auth_pattern: :jsonrpc_linebreak,
      auth_config: %{}
    },
    "derive" => %{
      public_url: "wss://api.lyra.finance/ws",
      public_url_sandbox: "wss://api-demo.lyra.finance/ws",
      private_url: "wss://api.lyra.finance/ws",
      private_url_sandbox: "wss://api-demo.lyra.finance/ws",
      heartbeat: %{type: :ping, interval: 9_000},
      # Derive wire shape: {"method":"subscribe","params":{"channels":[...]}}
      # Registered atom is :method_params_subscribe (MethodParams); bare
      # :method_params has no module_for_pattern clause and falls through to nil.
      subscription_pattern: :method_params_subscribe,
      subscription_config: %{channel_key: "channels"},
      auth_pattern: :eip191_jsonrpc_login,
      auth_config: %{}
    },
    "hyperliquid" => %{
      public_url: "wss://api.hyperliquid.xyz/ws",
      public_url_sandbox: "wss://api.hyperliquid-testnet.xyz/ws",
      private_url: nil,
      private_url_sandbox: nil,
      heartbeat: %{type: :ping, interval: 20_000},
      subscription_pattern: :method_subscription,
      subscription_config: %{},
      auth_pattern: nil,
      auth_config: %{}
    },
    "lighter" => %{
      public_url: "wss://mainnet.zklighter.elliot.ai/stream",
      public_url_sandbox: "wss://testnet.zklighter.elliot.ai/stream",
      private_url: nil,
      private_url_sandbox: nil,
      heartbeat: %{type: :ping, interval: @public_heartbeat_interval_ms},
      subscription_pattern: :type_subscribe,
      subscription_config: %{args_field: "channel", args_format: :string},
      auth_pattern: nil,
      auth_config: %{}
    }
  }

  @doc "Hand-maintained bases keyed by exchange id (subscription + URL/auth detail)."
  @spec hand_bases() :: %{String.t() => map()}
  def hand_bases, do: @hand_bases

  defp load_spec(exchange_id) do
    Spec.load!(exchange_id)
  rescue
    # Only swallow the expected "spec missing / malformed" failures; let genuine bugs propagate.
    _ in [File.Error, Jason.DecodeError, RuntimeError, ArgumentError] -> nil
  end

  defp merge_urls(config, _exchange_id, spec) do
    case resolved_urls(spec) do
      nil ->
        config

      urls ->
        config
        |> Map.put(:public_url, urls.public)
        |> Map.put(:private_url, urls.private)
        |> Map.put(:public_url_sandbox, urls.sandbox_public)
        |> Map.put(:private_url_sandbox, urls.sandbox_private)
        |> Map.put(:market_url, urls.market)
        |> Map.put(:market_url_sandbox, urls.sandbox_market)
    end
  end

  defp resolved_urls(spec) do
    case get_in(spec, ["websocket", "urls"]) do
      %{"unresolved_reason" => nil} = urls ->
        %{
          public: Map.get(urls, "public"),
          private: Map.get(urls, "private"),
          sandbox_public: Map.get(urls, "sandbox_public"),
          sandbox_private: Map.get(urls, "sandbox_private"),
          market: Map.get(urls, "market"),
          sandbox_market: Map.get(urls, "sandbox_market")
        }

      _ ->
        nil
    end
  end

  defp merge_heartbeat(config, exchange_id, spec) do
    case get_in(spec, ["websocket", "heartbeat"]) do
      %{"unresolved_reason" => nil} = hb ->
        Map.put(config, :heartbeat, heartbeat_from_spec(exchange_id, hb, config))

      _ ->
        config
    end
  end

  defp heartbeat_from_spec(exchange_id, hb, config) do
    hand = Map.get(config, :heartbeat, %{})
    interval = Map.get(hb, "keep_alive_ms") || Map.get(hand, :interval)

    base = %{
      type: heartbeat_type(exchange_id, Map.get(hb, "ping_kind"), hand),
      interval: interval
    }

    case Map.get(hb, "ping_payload") do
      payload when is_map(payload) or is_binary(payload) ->
        Map.put(base, :payload, payload)

      _ ->
        base
    end
  end

  defp heartbeat_type("deribit", "native_frame", _hand), do: :deribit

  defp heartbeat_type(_exchange_id, "native_frame", hand) do
    Map.get(hand, :type, :ping)
  end

  defp heartbeat_type(_exchange_id, "json_message", hand), do: Map.get(hand, :type, :custom)
  defp heartbeat_type(_exchange_id, "string_message", hand), do: Map.get(hand, :type, :custom)
  defp heartbeat_type(_exchange_id, _kind, hand), do: Map.get(hand, :type, :ping)

  defp merge_auth(config, _exchange_id, spec) do
    case get_in(spec, ["websocket", "auth"]) do
      %{"unresolved_reason" => nil} = auth ->
        case auth_pattern_from_spec(auth, config) do
          {pattern, auth_config} ->
            config
            |> Map.put(:auth_pattern, pattern)
            |> Map.put(:auth_config, auth_config)

          :keep_hand ->
            config
        end

      _ ->
        config
    end
  end

  defp auth_pattern_from_spec(%{"mechanism" => "none"}, _config), do: {nil, %{}}

  defp auth_pattern_from_spec(%{"mechanism" => "url_param"}, config) do
    {:listen_key, Map.get(config, :auth_config, %{})}
  end

  defp auth_pattern_from_spec(%{"mechanism" => "sign_in_message", "message" => %{"op" => "auth", "keys" => keys}}, config)
       when is_list(keys) do
    pattern = if Enum.sort(keys) == ~w(action key secret), do: :action_key_secret, else: :direct_hmac_expiry
    {pattern, Map.get(config, :auth_config, %{})}
  end

  defp auth_pattern_from_spec(%{"mechanism" => "sign_in_message", "message" => message}, config) when is_map(message) do
    hand_pattern = Map.get(config, :auth_pattern)
    hand_config = Map.get(config, :auth_config, %{})

    case message do
      %{"op" => "auth"} ->
        {:direct_hmac_expiry, hand_config}

      %{"op" => "login"} ->
        {:iso_passphrase, hand_config}

      %{"method" => "public/auth"} ->
        {:jsonrpc_linebreak, hand_config}

      # Binance spot: the signed WS-API request that opens the user data
      # stream. Named rather than left to the fallback below, because the
      # fallback silently keeps whatever the hand base says.
      %{"method" => "userDataStream.subscribe.signature"} ->
        {:ws_api_signature, hand_config}

      %{"method" => "public/login"} ->
        {:eip191_jsonrpc_login, hand_config}

      _ ->
        if hand_pattern, do: {hand_pattern, hand_config}, else: :keep_hand
    end
  end

  defp auth_pattern_from_spec(_auth, _config), do: :keep_hand
end
