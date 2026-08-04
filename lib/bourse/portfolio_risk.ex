defmodule Bourse.PortfolioRisk do
  @moduledoc """
  Builds point-in-time portfolio risk across venue/account domains.

  The reader performs no writes and holds no state. Balances, positions, and
  open orders remain attached to their originating venue/account domain.
  Aggregates contain only compatible exposure buckets; failures and blocked
  buckets make incomplete results explicit.
  """

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.PortfolioRisk.Exposure
  alias Bourse.PortfolioRisk.Snapshot
  alias Bourse.Unified.GreeksConventions
  alias Bourse.Unified.OptionSurface

  @default_timeout_ms 10_000
  @components [:balance, :positions, :open_orders]

  @type scope :: %{
          required(:exchange) => Exchange.t(),
          required(:account) => term(),
          optional(:request_opts) => keyword()
        }

  @doc "Builds one venue/account scope for `snapshot/2`."
  @spec scope(Exchange.t(), term(), keyword()) :: scope()
  def scope(%Exchange{} = exchange, account, request_opts \\ []) when is_list(request_opts) do
    %{exchange: exchange, account: account, request_opts: request_opts}
  end

  @doc """
  Reads and composes a multi-venue portfolio-risk snapshot.

  Options:

    * `:timeout` — per-scope and per-component task timeout
    * `:observed_at` — local observation timestamp override
    * `:max_age_ms` — optional source-timestamp freshness limit for Greeks
  """
  @spec snapshot([scope()], keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def snapshot(scopes, opts \\ []) when is_list(scopes) and is_list(opts) do
    observed_at = Keyword.get(opts, :observed_at, System.system_time(:millisecond))
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    max_age_ms = Keyword.get(opts, :max_age_ms)

    with :ok <- validate_options(observed_at, timeout, max_age_ms),
         :ok <- validate_scopes(scopes) do
      scopes = Enum.map(scopes, &Map.put_new(&1, :request_opts, []))
      domains = collect_domains(scopes, observed_at, timeout)
      {domains, contributions, blocked, failures} = analyze_domains(domains, observed_at, timeout, max_age_ms)
      aggregates = Exposure.aggregate(contributions, blocked)
      status = if failures == [] and blocked == [], do: :complete, else: :partial

      {:ok,
       %Snapshot{
         status: status,
         observed_at: observed_at,
         domains: Enum.map(domains, &Map.drop(&1, [:exchange, :request_opts])),
         contributions: contributions,
         aggregates: aggregates,
         blocked_buckets: blocked,
         failures: failures
       }}
    end
  end

  defp collect_domains(scopes, observed_at, timeout) do
    scopes
    |> Task.async_stream(&collect_domain(&1, observed_at, timeout),
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(scopes)
    |> Enum.map(fn
      {{:ok, domain}, _scope} -> domain
      {{:exit, reason}, scope} -> failed_domain(scope, observed_at, normalize_exit(reason))
    end)
  end

  defp collect_domain(scope, observed_at, timeout) do
    {exchange, markets_component} = ensure_markets(scope.exchange, scope.request_opts, observed_at)
    components = collect_components(exchange, scope.request_opts, observed_at, timeout)

    put_domain_state(%{
      venue: exchange.id,
      account: scope.account,
      exchange: exchange,
      request_opts: scope.request_opts,
      components: Map.put(components, :markets, markets_component)
    })
  end

  defp ensure_markets(%Exchange{markets: markets} = exchange, _request_opts, observed_at)
       when is_list(markets) and markets != [] do
    {exchange, component_ok(markets, observed_at, nil)}
  end

  defp ensure_markets(exchange, request_opts, observed_at) do
    case safe_call(fn -> Bourse.load_markets(exchange, request_opts) end) do
      {:ok, %Exchange{} = loaded} ->
        {loaded, component_ok(loaded.markets, observed_at, nil)}

      {:error, reason} ->
        {exchange, component_error(reason, observed_at)}
    end
  end

  defp collect_components(exchange, request_opts, observed_at, timeout) do
    @components
    |> Task.async_stream(
      fn component ->
        {component, read_component(component, exchange, request_opts, observed_at)}
      end,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(@components)
    |> Map.new(fn
      {{:ok, {component, result}}, _expected} -> {component, result}
      {{:exit, reason}, component} -> {component, component_error(normalize_exit(reason), observed_at)}
    end)
  end

  defp read_component(component, exchange, request_opts, observed_at) do
    result =
      case component do
        :balance -> safe_call(fn -> Bourse.fetch_balance(exchange, request_opts) end)
        :positions -> safe_call(fn -> Bourse.fetch_positions(exchange, request_opts) end)
        :open_orders -> safe_call(fn -> Bourse.fetch_open_orders(exchange, request_opts) end)
      end

    case result do
      {:ok, data} -> component_ok(data, observed_at, source_timestamp(component, data))
      {:error, reason} -> component_error(reason, observed_at)
    end
  end

  defp analyze_domains(domains, observed_at, timeout, max_age_ms) do
    analyzed =
      Enum.map(domains, fn domain ->
        {contributions, blocked, failures} = analyze_domain(domain, observed_at, timeout, max_age_ms)
        {domain, contributions, blocked, failures}
      end)

    {
      Enum.map(analyzed, fn {domain, _c, _b, _f} -> domain end),
      Enum.flat_map(analyzed, fn {_d, contributions, _b, _f} -> contributions end),
      Enum.flat_map(analyzed, fn {_d, _c, blocked, _f} -> blocked end),
      Enum.flat_map(analyzed, fn {_d, _c, _b, failures} -> failures end)
    }
  end

  defp analyze_domain(domain, observed_at, timeout, max_age_ms) do
    provenance = %{venue: domain.venue, account: domain.account, observed_at: observed_at}
    component_failures = component_failures(domain)
    {delta_lots, option_lots, lot_failures} = build_lots(domain, provenance)
    delta_contributions = Enum.map(delta_lots, &Exposure.delta_contribution/1)

    {option_contributions, blocked, greek_failures} =
      option_risk(domain, option_lots, observed_at, timeout, max_age_ms)

    {delta_contributions ++ option_contributions, blocked, component_failures ++ lot_failures ++ greek_failures}
  end

  defp build_lots(domain, provenance) do
    balance_lots =
      case component_data(domain, :balance) do
        {:ok, balance} -> Exposure.balance_lots(provenance, balance)
        {:error, _reason} -> []
      end

    case component_data(domain, :markets) do
      {:ok, markets} ->
        {position_lots, position_failures} =
          record_lots(domain, provenance, :positions, markets, &Exposure.position_lot/3)

        {order_lots, order_failures} =
          record_lots(domain, provenance, :open_orders, markets, &Exposure.order_lots/3)

        lots = balance_lots ++ position_lots ++ order_lots
        {Enum.reject(lots, &option_lot?/1), Enum.filter(lots, &option_lot?/1), position_failures ++ order_failures}

      {:error, reason} ->
        failures =
          @components
          |> Enum.reject(&(&1 == :balance))
          |> Enum.flat_map(&market_component_failure(domain, &1, reason))

        {balance_lots, [], failures}
    end
  end

  defp market_component_failure(domain, component, reason) do
    case component_data(domain, component) do
      {:ok, []} -> []
      {:ok, _records} -> [failure(domain, :risk_resolution, nil, {:markets_unavailable, reason})]
      {:error, _component_reason} -> []
    end
  end

  defp record_lots(domain, provenance, component, markets, builder) do
    case component_data(domain, component) do
      {:ok, records} when is_list(records) ->
        Enum.reduce(records, {[], []}, fn record, acc ->
          append_record_lot(record, acc, domain, provenance, component, markets, builder)
        end)

      {:ok, other} ->
        {[], [failure(domain, component, nil, {:unexpected_component_shape, other})]}

      {:error, _reason} ->
        {[], []}
    end
  end

  defp append_record_lot(record, {lots, failures}, domain, provenance, component, markets, builder) do
    with symbol when is_binary(symbol) <- Map.get(record, :symbol),
         %Market{} = market <- find_market(markets, record),
         {:ok, built} <- builder.(provenance, record, market) do
      {lots ++ List.wrap(built), failures}
    else
      nil -> {lots, failures ++ [failure(domain, component, nil, :missing_symbol)]}
      false -> {lots, failures ++ [failure(domain, component, Map.get(record, :symbol), :market_not_found)]}
      {:error, reason} -> {lots, failures ++ [failure(domain, component, Map.get(record, :symbol), reason)]}
    end
  end

  defp option_risk(_domain, [], _observed_at, _timeout, _max_age_ms), do: {[], [], []}

  defp option_risk(domain, lots, observed_at, timeout, max_age_ms) do
    symbols = lots |> Enum.map(& &1.symbol) |> Enum.uniq()

    results =
      fetch_greeks(
        domain.exchange,
        domain.request_opts,
        symbols,
        observed_at,
        timeout,
        max_age_ms
      )

    Enum.reduce(lots, {[], [], []}, fn lot, acc ->
      accumulate_option_risk(lot, acc, domain, results)
    end)
  end

  defp accumulate_option_risk(lot, {contributions, blocked, failures}, domain, results) do
    case Map.fetch!(results, lot.symbol) do
      {:ok, %InstrumentGreeks{} = greeks} ->
        {contribution, missing} = Exposure.option_contribution(lot, greeks)
        missing_failures = Enum.map(missing, &failure_from_blocker(domain, &1))

        {
          append_if_present(contributions, contribution),
          blocked ++ missing,
          failures ++ missing_failures
        }

      {:error, reason} ->
        failed_option_risk(lot, contributions, blocked, failures, domain, reason)
    end
  end

  defp failed_option_risk(lot, contributions, blocked, failures, domain, reason) do
    case GreeksConventions.for_exchange(domain.exchange) do
      {:ok, conventions} ->
        blockers = Exposure.block_option(lot, conventions, reason)

        {
          contributions,
          blocked ++ blockers,
          failures ++ [failure(domain, :greeks, lot.symbol, reason)]
        }

      {:error, convention_error} ->
        {
          contributions,
          blocked,
          failures ++ [failure(domain, :greeks_conventions, lot.symbol, convention_error)]
        }
    end
  end

  defp fetch_greeks(exchange, request_opts, symbols, observed_at, timeout, max_age_ms) do
    symbols
    |> Task.async_stream(
      fn symbol ->
        opts = maybe_put_max_age([observed_at: observed_at, request_opts: request_opts], max_age_ms)

        {symbol, safe_call(fn -> OptionSurface.instrument_greeks(exchange, symbol, opts) end)}
      end,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(symbols)
    |> Map.new(fn
      {{:ok, {symbol, result}}, _expected} -> {symbol, result}
      {{:exit, reason}, symbol} -> {symbol, {:error, normalize_exit(reason)}}
    end)
  end

  defp put_domain_state(domain) do
    positions = component_data(domain, :positions)
    balance = component_data(domain, :balance)

    Map.merge(domain, %{
      margin: map_positions(positions, &margin_row/1),
      collateral: map_positions(positions, &collateral_row/1),
      available_capacity: map_balance(balance, & &1.free),
      account_modes: map_positions(positions, & &1.margin_mode, true),
      liquidation_state: map_positions(positions, &liquidation_row/1)
    })
  end

  defp map_positions(positions, mapper, uniq? \\ false)

  defp map_positions({:ok, positions}, mapper, uniq?) when is_list(positions) do
    values = positions |> Enum.map(mapper) |> Enum.reject(&is_nil/1)
    {:ok, if(uniq?, do: Enum.uniq(values), else: values)}
  end

  defp map_positions({:error, reason}, _mapper, _uniq?), do: {:error, reason}
  defp map_positions({:ok, other}, _mapper, _uniq?), do: {:error, {:unexpected_component_shape, other}}

  defp map_balance({:ok, balance}, mapper), do: {:ok, mapper.(balance)}
  defp map_balance({:error, reason}, _mapper), do: {:error, reason}

  defp margin_row(position) do
    %{
      symbol: position.symbol,
      margin: position.margin,
      initial_margin: position.initial_margin,
      maintenance_margin: position.maintenance_margin,
      margin_ratio: position.margin_ratio,
      margin_mode: position.margin_mode
    }
  end

  defp collateral_row(position) do
    %{symbol: position.symbol, collateral: position.collateral}
  end

  defp liquidation_row(position) do
    %{
      symbol: position.symbol,
      liquidation_price: position.liquidation_price,
      mark_price: position.mark_price,
      margin_ratio: position.margin_ratio
    }
  end

  defp component_failures(domain) do
    Enum.flat_map(domain.components, fn
      {_component, %{status: :ok}} -> []
      {component, %{status: :error, error: reason}} -> [failure(domain, component, nil, reason)]
    end)
  end

  defp component_data(domain, component) do
    case Map.fetch!(domain.components, component) do
      %{status: :ok, data: data} -> {:ok, data}
      %{status: :error, error: reason} -> {:error, reason}
    end
  end

  defp find_market(markets, record) do
    symbol = Map.get(record, :symbol)
    info = Map.get(record, :info)
    native_id = native_market_id(info)

    Enum.find(markets, false, fn
      %Market{symbol: ^symbol} -> true
      %Market{id: ^symbol} -> true
      %Market{id: ^native_id} when is_binary(native_id) -> true
      _other -> false
    end)
  end

  defp native_market_id(info) when is_map(info) do
    Enum.find_value(~w(instrument_name instId symbol), &Map.get(info, &1))
  end

  defp native_market_id(_info), do: nil

  defp option_lot?(%{market: %Market{option: true}}), do: true
  defp option_lot?(_lot), do: false

  defp component_ok(data, observed_at, source_timestamp) do
    %{status: :ok, data: data, source_timestamp: source_timestamp, observed_at: observed_at}
  end

  defp component_error(error, observed_at), do: %{status: :error, error: error, observed_at: observed_at}

  defp source_timestamp(:balance, %{timestamp: timestamp}), do: timestamp

  defp source_timestamp(component, records) when component in [:positions, :open_orders] and is_list(records) do
    records
    |> Enum.map(fn record -> Map.get(record, :last_update_timestamp) || Map.get(record, :timestamp) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp source_timestamp(_component, _data), do: nil

  defp failed_domain(scope, observed_at, reason) do
    components = Map.new([:markets | @components], &{&1, component_error(reason, observed_at)})

    %{
      venue: scope.exchange.id,
      account: scope.account,
      exchange: scope.exchange,
      request_opts: scope.request_opts,
      components: components,
      margin: {:error, reason},
      collateral: {:error, reason},
      available_capacity: {:error, reason},
      account_modes: {:error, reason},
      liquidation_state: {:error, reason}
    }
  end

  defp failure(domain, component, symbol, reason) do
    %{
      venue: domain.venue,
      account: domain.account,
      component: component,
      symbol: symbol,
      reason: reason,
      observed_at: domain.components |> Map.values() |> hd() |> Map.fetch!(:observed_at)
    }
  end

  defp failure_from_blocker(domain, blocker) do
    failure(domain, {:greek, blocker.bucket.greek}, blocker.symbol, blocker.reason)
  end

  defp validate_scopes([]), do: {:error, Error.invalid_parameters(message: "portfolio risk requires at least one scope")}

  defp validate_scopes(scopes) do
    with :ok <- validate_scope_shapes(scopes) do
      reject_duplicate_domains(scopes)
    end
  end

  defp validate_scope_shapes(scopes) do
    if Enum.all?(scopes, &valid_scope?/1) do
      :ok
    else
      {:error,
       Error.invalid_parameters(
         message: "each portfolio risk scope requires an exchange, non-nil account, and keyword request_opts"
       )}
    end
  end

  defp valid_scope?(%{exchange: %Exchange{}, account: account} = scope) do
    not is_nil(account) and is_list(Map.get(scope, :request_opts, []))
  end

  defp valid_scope?(_scope), do: false

  defp reject_duplicate_domains(scopes) do
    keys = Enum.map(scopes, &{&1.exchange.id, &1.account})

    if length(keys) == length(Enum.uniq(keys)) do
      :ok
    else
      {:error, Error.invalid_parameters(message: "portfolio risk scopes must have unique venue/account domains")}
    end
  end

  defp validate_options(observed_at, timeout, max_age_ms)
       when is_integer(observed_at) and is_integer(timeout) and timeout > 0 and
              (is_nil(max_age_ms) or (is_integer(max_age_ms) and max_age_ms >= 0)), do: :ok

  defp validate_options(_observed_at, _timeout, _max_age_ms) do
    {:error,
     Error.invalid_parameters(
       message: "observed_at must be an integer, timeout must be positive, and max_age_ms must be non-negative"
     )}
  end

  defp safe_call(fun) do
    case fun.() do
      {:ok, _value} = ok -> ok
      {:error, _reason} = error -> error
    end
  rescue
    # Intentional: convert any venue-read exception into a uniform {:error, _}
    # result so one scope's failure never becomes silent zero exposure.
    # reach:disable-next-line bare_rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_exit(:timeout), do: :timeout
  defp normalize_exit(reason), do: {:exit, reason}

  defp append_if_present(list, nil), do: list
  defp append_if_present(list, value), do: list ++ [value]

  defp maybe_put_max_age(opts, nil), do: opts
  defp maybe_put_max_age(opts, max_age_ms), do: Keyword.put(opts, :max_age_ms, max_age_ms)
end
