defmodule Bourse.Unified.OptionSurface do
  @moduledoc """
  Coherent option discovery and instrument-Greeks surface for option venues.

  Joins market identity with risk data by **canonical unified symbol**, preserves
  native provenance (`info`) and distinct source vs local observation timestamps,
  and fails explicitly on missing identity, ambiguous matches or stale data.
  """

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Greeks
  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.OptionData
  alias Bourse.OptionInstrument
  alias Bourse.Unified.GreeksConventions

  @option_types ~w(C P call put)
  @native_id_fields ~w(instrument_name instId symbol)

  @doc """
  Discovers active option calls and puts for a venue.

  Options:

    * `:base` / `"base"` — restrict to an underlying base currency
    * `:quotes` — when true (default), attempt to attach bid/ask/IV/OI via
      `fetch_option_chain` when available
    * `:observed_at` — override local observation time (tests)
    * `:request_opts` — options forwarded to venue HTTP calls
  """
  @spec discover(Exchange.t(), keyword() | map()) :: {:ok, [OptionInstrument.t()]} | {:error, Error.t()}
  def discover(%Exchange{} = exchange, opts \\ []) do
    opts = normalize_opts(opts)

    with {:ok, request_opts} <- request_opts(opts),
         {:ok, exchange} <- ensure_markets(exchange, request_opts),
         {:ok, markets} <- option_markets(exchange, opts),
         :ok <- validate_market_identities(markets),
         :ok <- reject_ambiguous_symbols(markets),
         {:ok, quotes} <- load_quotes(exchange, markets, opts, request_opts) do
      instruments = Enum.map(markets, &to_instrument(&1, exchange, Map.get(quotes, &1.symbol), opts))
      {:ok, instruments}
    end
  end

  @doc """
  Fetches instrument Greeks for one canonical symbol and joins market identity.

  Options:

    * `:max_age_ms` — when set, fails if source timestamp is missing or older
      than this many milliseconds relative to `observed_at`
    * `:observed_at` — override local observation time (tests)
    * `:request_opts` — options forwarded to venue HTTP calls
  """
  @spec instrument_greeks(Exchange.t(), String.t(), keyword() | map()) ::
          {:ok, InstrumentGreeks.t()} | {:error, Error.t()}
  def instrument_greeks(%Exchange{} = exchange, symbol, opts \\ []) when is_binary(symbol) do
    opts = normalize_opts(opts)

    with {:ok, request_opts} <- request_opts(opts),
         {:ok, exchange} <- ensure_markets(exchange, request_opts),
         {:ok, market} <- resolve_unique_market(exchange, symbol),
         {:ok, conventions} <- GreeksConventions.for_exchange(exchange),
         {:ok, %Greeks{} = greeks} <- Bourse.fetch_greeks(exchange, market.symbol, request_opts) do
      finalize_greeks(exchange, market, greeks, conventions, opts)
    end
  end

  @doc """
  Builds the joined option+Greeks surface for active instruments.

  Options:

    * `:base` / `"base"` — restrict discovery
    * `:limit` — cap the number of instruments whose Greeks are fetched
    * `:max_age_ms` — freshness gate applied per instrument
    * `:observed_at` — override local observation time (tests)
    * `:request_opts` — options forwarded to venue HTTP calls
  """
  @spec surface(Exchange.t(), keyword() | map()) ::
          {:ok, [%{instrument: OptionInstrument.t(), greeks: InstrumentGreeks.t()}]}
          | {:error, Error.t()}
  def surface(%Exchange{} = exchange, opts \\ []) do
    opts = normalize_opts(opts)

    with {:ok, request_opts} <- request_opts(opts),
         {:ok, exchange} <- ensure_markets(exchange, request_opts),
         {:ok, instruments} <- discover(exchange, opts) do
      join_instruments(exchange, maybe_limit(instruments, opts[:limit]), opts)
    end
  end

  defp join_instruments(exchange, instruments, opts) do
    result =
      Enum.reduce_while(instruments, {:ok, []}, fn instrument, {:ok, acc} ->
        append_instrument_greeks(exchange, instrument, opts, acc)
      end)

    case result do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      other -> other
    end
  end

  defp append_instrument_greeks(exchange, instrument, opts, acc) do
    case instrument_greeks(exchange, instrument.symbol, opts) do
      {:ok, greeks} ->
        instrument = enrich_instrument(instrument, greeks)
        {:cont, {:ok, [%{instrument: instrument, greeks: greeks} | acc]}}

      {:error, %Error{} = error} ->
        {:halt, {:error, error}}
    end
  end

  defp ensure_markets(%Exchange{markets: markets} = exchange, _request_opts) when is_list(markets) and markets != [] do
    {:ok, exchange}
  end

  defp ensure_markets(%Exchange{} = exchange, request_opts) do
    case Bourse.fetch_markets(exchange, request_opts) do
      {:ok, markets} -> {:ok, %{exchange | markets: markets}}
      {:error, %Error{}} = err -> err
      {:error, reason} -> {:error, Error.exchange_error("fetch_markets failed: #{inspect(reason)}")}
    end
  end

  defp option_markets(%Exchange{markets: markets}, opts) when is_list(markets) do
    base = opts[:base] || opts["base"]

    selected =
      Enum.filter(markets, fn market ->
        option_market?(market) and not Market.combo?(market) and market.active != false and
          (is_nil(base) or market.base == base)
      end)

    case selected do
      [] ->
        {:error, Error.bad_symbol(message: "no active option markets discovered" <> base_suffix(base))}

      list ->
        {:ok, list}
    end
  end

  defp option_market?(%Market{option: true}), do: true
  defp option_market?(%Market{type: "option"}), do: true
  defp option_market?(_), do: false

  defp load_quotes(%Exchange{} = exchange, markets, opts, request_opts) do
    quotes? = Map.get(opts, :quotes, true)

    cond do
      quotes? == false ->
        {:ok, %{}}

      Exchange.has?(exchange, "fetchOptionChain") ->
        load_option_chain_quotes(exchange, markets, request_opts)

      true ->
        {:ok, %{}}
    end
  end

  defp load_option_chain_quotes(%Exchange{} = exchange, markets, request_opts) do
    bases =
      markets
      |> Enum.map(& &1.base)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce_while(bases, {:ok, %{}}, fn base, {:ok, acc} ->
      merge_option_chain(exchange, base, acc, request_opts)
    end)
  end

  defp merge_option_chain(exchange, base, acc, request_opts) do
    case Bourse.fetch_option_chain(exchange, base, request_opts) do
      {:ok, chain} when is_map(chain) ->
        {:cont, {:ok, Map.merge(acc, chain)}}

      {:error, %Error{} = error} ->
        {:halt, {:error, error}}

      {:error, reason} ->
        {:halt, {:error, Error.exchange_error("fetch_option_chain failed for #{base}: #{inspect(reason)}")}}
    end
  end

  defp to_instrument(%Market{} = market, %Exchange{id: venue}, quote, opts) do
    %OptionInstrument{
      venue: venue,
      symbol: market.symbol,
      id: market.id,
      base: market.base,
      quote: market.quote,
      settle: market.settle,
      strike: market.strike,
      expiry: market.expiry,
      option_type: normalize_option_type(market.option_type),
      active: market.active,
      bid_price: quote_field(quote, :bid_price),
      ask_price: quote_field(quote, :ask_price),
      implied_volatility: quote_field(quote, :implied_volatility),
      open_interest: quote_field(quote, :open_interest),
      source_timestamp: quote_field(quote, :timestamp),
      observed_at: observation_time(opts, quote_field(quote, :observed_at)),
      info: %{"market" => market.info, "quote" => quote_info(quote)}
    }
  end

  defp quote_field(%OptionData{} = option, field), do: Map.get(option, field)
  defp quote_field(%Greeks{} = greeks, :observed_at), do: greeks.observed_at
  defp quote_field(%Greeks{} = greeks, :bid_price), do: greeks.bid_price
  defp quote_field(%Greeks{} = greeks, :ask_price), do: greeks.ask_price
  defp quote_field(%Greeks{} = greeks, :implied_volatility), do: greeks.mark_implied_volatility
  defp quote_field(%Greeks{} = greeks, :timestamp), do: greeks.timestamp
  defp quote_field(%Greeks{}, _field), do: nil
  defp quote_field(_, _), do: nil

  defp quote_info(%OptionData{info: info}), do: info
  defp quote_info(%Greeks{info: info}), do: info
  defp quote_info(_), do: nil

  defp validate_market_identities(markets) do
    Enum.reduce_while(markets, :ok, fn market, :ok ->
      case missing_identity_market(market) do
        [] ->
          {:cont, :ok}

        missing ->
          label = market.symbol || market.id || inspect(market.info)

          error =
            Error.bad_symbol(message: "incomplete option identity for #{label}: missing #{Enum.join(missing, ", ")}")

          {:halt, {:error, error}}
      end
    end)
  end

  defp reject_ambiguous_symbols(markets) do
    duplicates =
      markets
      |> Enum.group_by(& &1.symbol)
      |> Enum.filter(fn
        {_symbol, [_single]} -> false
        {_symbol, _many} -> true
      end)
      |> Enum.map(fn {symbol, _markets} -> symbol end)

    case duplicates do
      [] -> :ok
      symbols -> {:error, Error.bad_symbol(message: "ambiguous option market symbols: #{inspect(symbols)}")}
    end
  end

  defp resolve_unique_market(%Exchange{markets: markets}, symbol) when is_list(markets) do
    matches =
      Enum.filter(markets, fn market ->
        option_market?(market) and (market.symbol == symbol or market.id == symbol)
      end)

    case matches do
      [%Market{} = market] ->
        case missing_identity_market(market) do
          [] ->
            {:ok, market}

          missing ->
            {:error,
             Error.bad_symbol(message: "incomplete option identity for #{symbol}: missing #{Enum.join(missing, ", ")}")}
        end

      [] ->
        {:error, Error.bad_symbol(message: "option market not found for #{symbol}")}

      many ->
        {:error,
         Error.bad_symbol(
           message:
             "ambiguous option market match for #{symbol}: #{length(many)} candidates " <>
               inspect(Enum.map(many, & &1.symbol))
         )}
    end
  end

  defp join_greeks(%Exchange{id: venue}, %Market{} = market, %Greeks{} = greeks, conventions, observed_at) do
    %InstrumentGreeks{
      venue: venue,
      symbol: market.symbol,
      id: market.id,
      settle: market.settle,
      strike: market.strike,
      expiry: market.expiry,
      option_type: normalize_option_type(market.option_type),
      delta: greeks.delta,
      gamma: greeks.gamma,
      vega: greeks.vega,
      theta: greeks.theta,
      rho: greeks.rho,
      conventions: project_conventions(conventions, greeks),
      bid_price: greeks.bid_price,
      ask_price: greeks.ask_price,
      mark_implied_volatility: greeks.mark_implied_volatility,
      underlying_price: greeks.underlying_price,
      source_timestamp: greeks.timestamp,
      observed_at: observed_at,
      info: greeks.info
    }
  end

  defp finalize_greeks(exchange, market, greeks, conventions, opts) do
    observed_at = observation_time(opts, greeks.observed_at)

    with :ok <- validate_greeks_symbol(greeks, market),
         :ok <- validate_native_identity(greeks.info, market),
         :ok <- validate_convention_values(greeks, conventions),
         :ok <- reject_stale(greeks.timestamp, observed_at, opts[:max_age_ms]) do
      {:ok, join_greeks(exchange, market, greeks, conventions, observed_at)}
    end
  end

  defp validate_greeks_symbol(%Greeks{symbol: symbol}, %Market{symbol: symbol}) when is_binary(symbol), do: :ok

  defp validate_greeks_symbol(%Greeks{symbol: nil}, %Market{symbol: symbol}) do
    {:error, Error.operation_failed(message: "greeks response missing canonical symbol #{symbol}")}
  end

  defp validate_greeks_symbol(%Greeks{symbol: actual}, %Market{symbol: expected}) do
    {:error, Error.operation_failed(message: "greeks symbol mismatch: expected #{expected}, got #{inspect(actual)}")}
  end

  defp validate_native_identity(info, %Market{id: expected}) when is_map(info) do
    case Enum.find_value(@native_id_fields, &native_identity(info, &1)) do
      {_field, ^expected} ->
        :ok

      {field, actual} ->
        {:error,
         Error.operation_failed(
           message: "greeks native instrument mismatch: expected #{expected}, got #{inspect(actual)} from #{field}"
         )}

      nil ->
        {:error, Error.operation_failed(message: "greeks response missing native instrument identity for #{expected}")}
    end
  end

  defp validate_native_identity(_info, %Market{id: expected}) do
    {:error, Error.operation_failed(message: "greeks response missing native instrument identity for #{expected}")}
  end

  defp native_identity(info, field) do
    case Map.get(info, field) do
      value when is_binary(value) and value != "" -> {field, value}
      _other -> nil
    end
  end

  defp validate_convention_values(greeks, conventions) do
    Enum.reduce_while(GreeksConventions.names(), :ok, fn name, :ok ->
      validate_convention_value(name, Map.fetch!(conventions, name), greeks)
    end)
  end

  defp validate_convention_value(name, %{"supported" => false}, greeks) do
    case Map.get(greeks, String.to_existing_atom(name)) do
      nil -> {:cont, :ok}
      value -> {:halt, {:error, Error.operation_failed(message: "unsupported greek #{name} returned #{inspect(value)}")}}
    end
  end

  defp validate_convention_value(name, %{"supported" => true, "native_field" => field}, greeks) do
    value = Map.get(greeks, String.to_existing_atom(name))

    if is_nil(value) or not is_nil(native_field(greeks.info, field)) do
      {:cont, :ok}
    else
      error =
        Error.operation_failed(message: "populated greek #{name} is missing authored native source field #{field}")

      {:halt, {:error, error}}
    end
  end

  defp native_field(info, field) when is_map(info) and is_binary(field) do
    get_in(info, String.split(field, "."))
  end

  defp native_field(_info, _field), do: nil

  defp project_conventions(conventions, %Greeks{} = greeks) do
    Map.new(GreeksConventions.names(), fn name ->
      entry = Map.fetch!(conventions, name)
      value = Map.get(greeks, String.to_existing_atom(name))

      projected =
        entry
        |> Map.take(~w(supported native_field denomination unit bump_size time_basis))
        |> Map.put("value_present", not is_nil(value))

      {name, projected}
    end)
  end

  defp reject_stale(_source_ts, _observed_at, nil), do: :ok

  defp reject_stale(nil, _observed_at, max_age_ms) when is_integer(max_age_ms) do
    {:error, Error.operation_failed(message: "missing source timestamp; cannot enforce max_age_ms=#{max_age_ms}")}
  end

  defp reject_stale(source_ts, observed_at, max_age_ms)
       when is_integer(source_ts) and is_integer(observed_at) and is_integer(max_age_ms) and max_age_ms >= 0 do
    age = max(observed_at - source_ts, 0)

    if age <= max_age_ms do
      :ok
    else
      {:error, Error.operation_failed(message: "stale option greeks: source_age_ms=#{age} max_age_ms=#{max_age_ms}")}
    end
  end

  defp reject_stale(_source_ts, _observed_at, max_age_ms) do
    {:error, Error.invalid_parameters(message: "max_age_ms must be a non-negative integer, got #{inspect(max_age_ms)}")}
  end

  defp missing_identity_market(%Market{} = market) do
    [
      symbol: market.symbol,
      id: market.id,
      strike: market.strike,
      expiry: market.expiry,
      settle: market.settle,
      option_type: market.option_type
    ]
    |> Enum.filter(fn
      {:option_type, value} -> value not in @option_types
      {_key, value} -> is_nil(value) or value == ""
    end)
    |> Enum.map(fn {k, _} -> Atom.to_string(k) end)
  end

  defp normalize_option_type("C"), do: "call"
  defp normalize_option_type("P"), do: "put"
  defp normalize_option_type("call"), do: "call"
  defp normalize_option_type("put"), do: "put"
  defp normalize_option_type(other), do: other

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts

  defp observation_time(%{observed_at: ts}, _parsed_observed_at) when is_integer(ts), do: ts
  defp observation_time(%{"observed_at" => ts}, _parsed_observed_at) when is_integer(ts), do: ts
  defp observation_time(_opts, parsed_observed_at) when is_integer(parsed_observed_at), do: parsed_observed_at
  defp observation_time(_opts, _parsed_observed_at), do: System.system_time(:millisecond)

  defp request_opts(opts) do
    case Map.get(opts, :request_opts, Map.get(opts, "request_opts", [])) do
      request_opts when is_list(request_opts) or is_map(request_opts) ->
        {:ok, request_opts}

      other ->
        {:error, Error.invalid_parameters(message: "request_opts must be a keyword list or map, got #{inspect(other)}")}
    end
  end

  defp enrich_instrument(%OptionInstrument{} = instrument, %InstrumentGreeks{} = greeks) do
    %{
      instrument
      | bid_price: instrument.bid_price || greeks.bid_price,
        ask_price: instrument.ask_price || greeks.ask_price,
        implied_volatility: instrument.implied_volatility || greeks.mark_implied_volatility,
        open_interest: instrument.open_interest || native_open_interest(greeks.info),
        source_timestamp: instrument.source_timestamp || greeks.source_timestamp,
        observed_at: greeks.observed_at,
        info: Map.put(instrument.info, "greeks", greeks.info)
    }
  end

  defp native_open_interest(info) when is_map(info) do
    Enum.find_value(
      [Map.get(info, "openInterest"), Map.get(info, "open_interest"), get_in(info, ["stats", "open_interest"])],
      &Bourse.Safe.number/1
    )
  end

  defp native_open_interest(_info), do: nil

  defp maybe_limit(list, limit) when is_integer(limit) and limit > 0, do: Enum.take(list, limit)
  defp maybe_limit(list, _), do: list

  defp base_suffix(nil), do: ""
  defp base_suffix(base), do: " for base #{base}"
end
