defmodule Bourse.WS.Channels do
  @moduledoc """
  Spec-driven WebSocket channel formatting from `websocket.subscribe.channels`.

  Maps unified `watch_*` methods to exchange-native channel strings (or OKX-style
  channel objects) using authored template strings.

  When a method has no resolvable templates or carries a non-nil
  `_unresolved_reason`, pass the pre-formatted channel via `channel:` in opts
  (honest pass-through — no guessing).
  """

  alias Bourse.Exchange
  alias Bourse.Symbol
  alias Bourse.WS.Config

  @js_methods %{
    watch_ticker: "watchTicker",
    watch_order_book: "watchOrderBook",
    watch_trades: "watchTrades",
    watch_orders: "watchOrders"
  }

  @method_fallbacks %{
    "watchTicker" => ["watchTickers"],
    "watchOrderBook" => ["watchOrderBookForSymbols"],
    "watchTrades" => ["watchTradesForSymbols"]
  }

  @any_channels %{
    watch_orders: "orders",
    watch_trades: "trades"
  }

  @private_methods [:watch_orders]

  @no_symbol_append_patterns [:op_subscribe_objects, :method_subscription]

  @type channel :: String.t() | map()
  @type params :: %{
          optional(:symbol) => String.t(),
          optional(:limit) => non_neg_integer(),
          optional(:timeframe) => String.t()
        }

  @type build_error ::
          :unsupported_method
          | :missing_symbol
          | :no_channel_templates
          | {:unresolved, String.t()}

  @doc "Returns whether the unified watch method requires a private WS connection."
  @spec private?(atom()) :: boolean()
  def private?(method) when is_atom(method), do: method in @private_methods

  @doc """
  Builds the exchange-native channel(s) for a unified watch method.

  Reads templates from `exchange.spec["websocket"]["subscribe"]["channels"]`.
  Returns a single channel value (string or map) suitable for `Bourse.WS.subscribe/3`.

  Pass `channel:` in opts to supply a pre-formatted channel when templates are
  missing or flagged with `_unresolved_reason`.
  """
  @spec build(Exchange.t(), atom(), params(), keyword()) ::
          {:ok, channel()} | {:error, build_error()}
  def build(%Exchange{} = exchange, method, params, opts \\ []) when is_atom(method) do
    with {:ok, js_method} <- js_method(method),
         {:ok, templates} <- lookup_templates(exchange, js_method),
         template = pick_template(templates, params, opts, exchange),
         {:ok, formatted} <- format_template(exchange, method, template, params, opts),
         {:ok, validated} <- validate_channel(formatted, template, params) do
      {:ok, validated}
    else
      {:error, _reason} = err ->
        case pass_through(opts) do
          {:ok, channel} -> {:ok, channel}
          :error -> err
        end
    end
  end

  @spec js_method(atom()) :: {:ok, String.t()} | {:error, :unsupported_method}
  defp js_method(method) do
    case Map.fetch(@js_methods, method) do
      {:ok, js} -> {:ok, js}
      :error -> {:error, :unsupported_method}
    end
  end

  @spec lookup_templates(Exchange.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :no_channel_templates | {:unresolved, String.t()}}
  defp lookup_templates(%Exchange{spec: spec}, js_method) do
    channels = get_in(spec, ["websocket", "subscribe", "channels"]) || %{}

    case template_entry(channels, js_method) do
      {:ok, templates} -> {:ok, templates}
      :missing -> {:error, :no_channel_templates}
      {:unresolved, reason} -> {:error, {:unresolved, reason}}
    end
  end

  @spec template_entry(map(), String.t()) ::
          {:ok, [String.t()]} | :missing | {:unresolved, String.t()}
  defp template_entry(channels, js_method) do
    case Map.get(channels, js_method) do
      %{"_unresolved_reason" => reason} when is_binary(reason) ->
        {:unresolved, reason}

      templates when is_list(templates) and templates != [] ->
        {:ok, templates}

      _ ->
        case fallback_templates(channels, js_method) do
          nil -> :missing
          {:unresolved, reason} -> {:unresolved, reason}
          templates -> {:ok, templates}
        end
    end
  end

  @spec fallback_templates(map(), String.t()) :: [String.t()] | nil | {:unresolved, String.t()}
  defp fallback_templates(channels, js_method) do
    @method_fallbacks
    |> Map.get(js_method, [])
    |> Enum.find_value(fn fallback ->
      case Map.get(channels, fallback) do
        %{"_unresolved_reason" => reason} when is_binary(reason) -> {:unresolved, reason}
        templates when is_list(templates) and templates != [] -> templates
        _ -> nil
      end
    end)
  end

  @spec pick_template([String.t()], params(), keyword(), Exchange.t()) :: String.t()
  defp pick_template(templates, params, opts, exchange) do
    templates
    |> Enum.map(&{score_template(&1, templates, params, opts, exchange), &1})
    |> Enum.max_by(fn {score, _} -> score end, fn -> {0, List.first(templates)} end)
    |> elem(1)
  end

  @spec score_template(String.t(), [String.t()], params(), keyword(), Exchange.t()) :: integer()
  defp score_template(template, templates, params, opts, exchange) do
    template
    |> template_score(templates, params, opts, exchange)
    |> Enum.sum()
  end

  @spec template_score(String.t(), [String.t()], params(), keyword(), Exchange.t()) :: [integer()]
  defp template_score(template, templates, params, opts, exchange) do
    symbol? = is_binary(params[:symbol])
    limit? = is_integer(params[:limit])
    timeframe? = is_binary(params[:timeframe]) or is_binary(opts[:timeframe])

    [
      score_static(symbol?, template, templates, exchange),
      score_symbol_placeholder(symbol?, template),
      score_limit_placeholder(limit?, template),
      score_timeframe_placeholder(timeframe?, template),
      score_default_timeframe(template),
      score_missing_symbol(symbol?, template),
      score_any_with_symbol(template, symbol?)
    ]
  end

  defp score_static(true, template, templates, exchange) do
    {pattern, _} = subscription_settings(exchange)

    cond do
      not static_channel_base?(template) ->
        0

      pattern == :method_subscription and Enum.any?(templates, &valid_symbol_template?/1) ->
        0

      true ->
        20
    end
  end

  defp score_static(false, _template, _templates, _exchange), do: 0

  @spec valid_symbol_template?(String.t()) :: boolean()
  defp valid_symbol_template?(template) do
    String.contains?(template, "{symbol}") and template not in [".{symbol}", ":{symbol}"]
  end

  defp score_symbol_placeholder(true, template), do: if(String.contains?(template, "{symbol}"), do: 10, else: 0)
  defp score_symbol_placeholder(false, _template), do: 0

  defp score_limit_placeholder(true, template), do: if(String.contains?(template, "{limit}"), do: 10, else: 0)
  defp score_limit_placeholder(false, _template), do: 0

  defp score_timeframe_placeholder(true, template), do: if(String.contains?(template, "{timeframe}"), do: 10, else: 0)

  defp score_timeframe_placeholder(false, _template), do: 0

  defp score_default_timeframe(template) do
    if String.contains?(template, "{timeframe}") and default_timeframe(template), do: 5, else: 0
  end

  defp score_missing_symbol(false, template), do: if(String.contains?(template, "{symbol}"), do: -10, else: 0)
  defp score_missing_symbol(true, _template), do: 0

  defp score_any_with_symbol("ANY", true), do: -5
  defp score_any_with_symbol(_template, _symbol?), do: 0

  @spec static_channel_base?(String.t()) :: boolean()
  defp static_channel_base?(template) do
    template not in ["ANY"] and not String.contains?(template, "{") and
      Regex.match?(~r/^[A-Za-z0-9_.-]+$/, template)
  end

  @spec format_template(Exchange.t(), atom(), String.t(), params(), keyword()) ::
          {:ok, channel()} | {:error, :missing_symbol}
  defp format_template(exchange, method, "ANY", _params, _opts) do
    case Map.fetch(@any_channels, method) do
      {:ok, channel_name} -> wrap_channel(exchange, method, channel_name, nil)
      :error -> {:error, :missing_symbol}
    end
  end

  defp format_template(exchange, method, template, params, opts) do
    with :ok <- require_symbol_for_template(template, params),
         {:ok, market_id} <- market_id(exchange, params) do
      interpolated = interpolate(template, market_id, params, opts)
      channel = combine_with_symbol(interpolated, template, market_id, exchange)
      wrap_channel(exchange, method, channel, market_id)
    end
  end

  @spec require_symbol_for_template(String.t(), params()) :: :ok | {:error, :missing_symbol}
  defp require_symbol_for_template(_template, %{symbol: symbol}) when is_binary(symbol), do: :ok

  defp require_symbol_for_template(template, _params) do
    if symbol_only_template?(template), do: {:error, :missing_symbol}, else: :ok
  end

  @spec symbol_only_template?(String.t()) :: boolean()
  defp symbol_only_template?(template) do
    template in ["{symbol}", ":{symbol}"] or Regex.match?(~r/^:?(\{symbol\})$/, template)
  end

  @spec market_id(Exchange.t(), params()) :: {:ok, String.t() | nil}
  defp market_id(%Exchange{} = exchange, %{symbol: symbol}) when is_binary(symbol) do
    raw = Symbol.to_exchange_id(symbol, exchange)
    {:ok, normalize_market_id(raw, subscription_settings(exchange))}
  end

  defp market_id(_exchange, _params), do: {:ok, nil}

  @spec normalize_market_id(String.t(), subscription_settings()) :: String.t()
  defp normalize_market_id(market_id, {_pattern, %{market_id_format: :lowercase}}) do
    market_id
    |> String.replace("/", "")
    |> String.downcase()
  end

  defp normalize_market_id(market_id, _settings), do: market_id

  @spec interpolate(String.t(), String.t() | nil, params(), keyword()) :: String.t()
  defp interpolate(template, market_id, params, opts) do
    limit = params[:limit]
    timeframe = params[:timeframe] || opts[:timeframe] || default_timeframe(template)

    template
    |> String.replace("{symbol}", market_id || "")
    |> String.replace("{limit}", (limit && Integer.to_string(limit)) || "")
    |> String.replace("{timeframe}", timeframe || "")
    |> collapse_separators()
  end

  @spec default_timeframe(String.t()) :: String.t() | nil
  defp default_timeframe(template) do
    if String.contains?(template, "{timeframe}"), do: "100ms"
  end

  @spec collapse_separators(String.t()) :: String.t()
  defp collapse_separators(channel) do
    channel
    |> String.replace(~r/\.{2,}/, ".")
    |> String.replace(~r/:{2,}/, ":")
    |> String.trim(".")
    |> String.trim(":")
  end

  @type subscription_settings :: {atom() | nil, map()}

  @spec subscription_settings(Exchange.t()) :: subscription_settings()
  defp subscription_settings(%Exchange{} = exchange) do
    case Config.for_exchange(exchange) || parent_config(exchange.spec) do
      %{subscription_pattern: pattern, subscription_config: sub_config} ->
        {pattern, sub_config}

      nil ->
        {infer_subscription_pattern(exchange.spec), %{}}
    end
  end

  @spec parent_config(map()) :: map() | nil
  defp parent_config(spec) do
    case get_in(spec, ["websocket", "subscribe", "resolved_from"]) do
      parent when is_binary(parent) -> Config.for_exchange(parent)
      _ -> nil
    end
  end

  @spec infer_subscription_pattern(map()) :: atom() | nil
  defp infer_subscription_pattern(spec) do
    spec
    |> get_in(["websocket", "subscribe"])
    |> infer_from_subscribe()
  end

  @spec infer_from_subscribe(map() | nil) :: atom() | nil
  defp infer_from_subscribe(%{"discriminant" => "op", "args_key" => "args"} = sub) do
    if object_channel_templates?(sub["channels"]), do: :op_subscribe_objects, else: :op_subscribe
  end

  defp infer_from_subscribe(%{"discriminant" => "method", "subscribe_op" => op}) when op in ["subscribe", "unsubscribe"],
    do: :method_subscription

  defp infer_from_subscribe(%{"discriminant" => "method", "subscribe_op" => op}) when is_binary(op),
    do: :jsonrpc_subscribe

  defp infer_from_subscribe(_), do: nil

  @spec object_channel_templates?(map() | nil) :: boolean()
  defp object_channel_templates?(channels) when is_map(channels) do
    Enum.any?(channels, fn
      {_method, ["ANY" | _]} -> true
      {_method, [template | _]} when is_binary(template) -> String.contains?(template, "{")
      _ -> false
    end)
  end

  defp object_channel_templates?(_), do: false

  @spec combine_with_symbol(String.t(), String.t(), String.t() | nil, Exchange.t()) :: String.t()
  defp combine_with_symbol(channel, template, market_id, exchange) do
    settings = subscription_settings(exchange)
    {pattern, _sub_config} = settings

    cond do
      template in ["ANY"] or String.contains?(template, "{symbol}") ->
        channel

      pattern in @no_symbol_append_patterns ->
        channel

      is_binary(market_id) and market_id != "" ->
        {separator, position} = symbol_placement(settings)

        case position do
          :prefix -> market_id <> separator <> channel
          :suffix -> channel <> separator <> market_id
        end

      true ->
        channel
    end
  end

  @spec symbol_placement(subscription_settings()) :: {String.t(), :prefix | :suffix}
  defp symbol_placement({:method_subscribe, sub_config}) do
    {Map.get(sub_config, :separator, "@"), Map.get(sub_config, :symbol_position, :prefix)}
  end

  defp symbol_placement({:op_subscribe, sub_config}) do
    {Map.get(sub_config, :separator, "."), Map.get(sub_config, :symbol_position, :suffix)}
  end

  defp symbol_placement(_), do: {".", :suffix}

  @spec validate_channel(channel(), String.t(), params()) ::
          {:ok, channel()} | {:error, :missing_symbol}
  defp validate_channel("", _template, _params), do: {:error, :missing_symbol}
  defp validate_channel(channel, _template, _params), do: {:ok, channel}

  @spec pass_through(keyword()) :: {:ok, channel()} | :error
  defp pass_through(opts) do
    case Keyword.get(opts, :channel) do
      channel when is_binary(channel) -> {:ok, channel}
      _ -> :error
    end
  end

  @spec wrap_channel(Exchange.t(), atom(), String.t(), String.t() | nil) ::
          {:ok, channel()} | {:error, :missing_symbol}
  defp wrap_channel(%Exchange{} = exchange, method, channel, market_id) do
    case subscription_settings(exchange) do
      {:op_subscribe_objects, _} ->
        channel_name =
          case channel do
            "ANY" -> Map.get(@any_channels, method, "orders")
            other -> other
          end

        base = %{"channel" => channel_name}

        wrapped =
          if is_binary(market_id) and market_id != "" do
            Map.put(base, "instId", market_id)
          else
            base
          end

        {:ok, wrapped}

      _ ->
        {:ok, channel}
    end
  end
end
