defmodule Bourse.OptionReadiness.Collector do
  @moduledoc """
  Mechanical, reproducible evidence collection for one option-readiness venue.

  Collectors capture observations and errors without deciding
  `client_broken` versus `venue_degraded`. Mutations (create/fetch/cancel) run
  only when `:mutate` is true. Fill attestation is never invented from a
  create/cancel lifecycle.
  """

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.OptionProposal
  alias Bourse.OptionReadiness.Cell
  alias Bourse.OptionReadiness.VenueRow
  alias Bourse.Order
  alias Bourse.PortfolioRisk
  alias Bourse.Ticker
  alias Bourse.Unified.OptionSurface

  @default_base %{
    "deribit" => "BTC",
    "okx" => "BTC",
    "bybit" => "BTC",
    "derive" => "ETH"
  }
  @default_max_age_ms 60_000
  @default_lifecycle_price 0.0001
  @derive_min_option_price 0.1
  @derive_readiness_max_fee "100"

  @doc "Collects every matrix cell for one venue."
  @spec collect(String.t(), Exchange.t(), String.t(), keyword(), integer(), keyword()) ::
          {:ok, VenueRow.t()} | {:error, Error.t()}
  def collect(venue, %Exchange{} = exchange, environment, request_opts, observed_at, opts)
      when is_binary(venue) and is_list(request_opts) and is_integer(observed_at) and is_list(opts) do
    base = Keyword.get(opts, :base, Map.fetch!(@default_base, venue))
    mutate? = Keyword.get(opts, :mutate, false)

    {exchange, discovery} = collect_discovery(exchange, venue, base, environment, observed_at, request_opts)
    instruments = discovery_instruments(discovery)

    greeks = collect_greeks(exchange, instruments, environment, observed_at, request_opts)
    balances = collect_balances(exchange, environment, observed_at, request_opts)
    positions = collect_positions(exchange, environment, observed_at, request_opts)
    open_orders = collect_open_orders(exchange, environment, observed_at, request_opts)

    lifecycle = collect_lifecycle(exchange, instruments, environment, observed_at, request_opts, mutate?)

    book = observe_book(discovery, observed_at)

    {preflight, hedge} =
      collect_preflight_and_hedge(exchange, instruments, greeks, environment, observed_at, request_opts, opts)

    limitation =
      book_limitation(book) ||
        Keyword.get(opts, :limitation) ||
        get_in(opts, [:venue_evidence, :limitation])

    cells = %{
      discovery: discovery.cell,
      greeks: greeks.cell,
      balances: balances,
      positions: positions,
      open_orders: open_orders,
      create_fetch_cancel: lifecycle,
      preflight: preflight,
      hedge: hedge
    }

    VenueRow.new(venue, cells,
      environment: environment,
      host: injected_evidence(opts, :host),
      observed_at: observed_at,
      book: book,
      limitation: limitation,
      fill_evidence: injected_evidence(opts, :fill_evidence),
      short_evidence: injected_evidence(opts, :short_evidence),
      judgment: Keyword.get(opts, :judgment) || get_in(opts, [:venue_evidence, :judgment])
    )
  end

  defp injected_evidence(opts, key) do
    Keyword.get(opts, key) ||
      get_in(opts, [:venue_evidence, key]) ||
      get_in(opts, [:venue_evidence, Atom.to_string(key)])
  end

  defp collect_discovery(exchange, venue, base, environment, observed_at, request_opts) do
    exchange = maybe_load_markets(exchange, request_opts)

    case discover_with_fallback(exchange, base, request_opts) do
      {:ok, instruments, used_base} ->
        cell =
          Cell.new(:discovery,
            outcome: if(instruments == [], do: :empty, else: :ok),
            observed_at: observed_at,
            environment: environment,
            summary: "#{length(instruments)} option instruments for base=#{inspect(used_base)}",
            evidence: %{
              venue: venue,
              base: used_base,
              count: length(instruments),
              sample_symbols: instruments |> Enum.take(5) |> Enum.map(& &1.symbol)
            }
          )

        {exchange, %{cell: cell, instruments: instruments}}

      {:error, %Error{} = error} ->
        cell =
          Cell.new(:discovery,
            outcome: :error,
            observed_at: observed_at,
            environment: environment,
            summary: error.message,
            error: error_evidence(error)
          )

        {exchange, %{cell: cell, instruments: []}}
    end
  end

  defp discover_with_fallback(exchange, base, request_opts) do
    case OptionSurface.discover(exchange, base: base, quotes: true, request_opts: request_opts) do
      {:ok, [_ | _] = instruments} ->
        {:ok, instruments, base}

      {:ok, []} ->
        case OptionSurface.discover(exchange, quotes: true, request_opts: request_opts) do
          {:ok, instruments} -> {:ok, instruments, :all}
          {:error, _} = error -> error
        end

      {:error, %Error{}} = first_error ->
        case OptionSurface.discover(exchange, quotes: true, request_opts: request_opts) do
          {:ok, instruments} -> {:ok, instruments, :all}
          {:error, _} -> first_error
        end
    end
  end

  defp collect_greeks(_exchange, [], environment, observed_at, _request_opts) do
    %{
      cell:
        Cell.new(:greeks,
          outcome: :empty,
          observed_at: observed_at,
          environment: environment,
          summary: "no instruments available for Greeks"
        ),
      value: nil
    }
  end

  defp collect_greeks(exchange, instruments, environment, observed_at, request_opts) do
    sample = pick_sample(instruments)

    case OptionSurface.instrument_greeks(exchange, sample.symbol, request_opts: request_opts) do
      {:ok, greeks} ->
        %{
          cell:
            Cell.new(:greeks,
              outcome: :ok,
              observed_at: observed_at,
              environment: environment,
              summary: "greeks for #{sample.symbol}",
              evidence: %{
                symbol: greeks.symbol,
                delta: greeks.delta,
                gamma: greeks.gamma,
                theta: greeks.theta,
                vega: greeks.vega,
                conventions: greeks.conventions,
                underlying_price: greeks.underlying_price,
                source_timestamp: greeks.source_timestamp,
                locally_observed_at: greeks.observed_at || observed_at
              }
            ),
          value: greeks
        }

      {:error, %Error{} = error} ->
        %{
          cell:
            Cell.new(:greeks,
              outcome: :error,
              observed_at: observed_at,
              environment: environment,
              summary: error.message,
              error: error_evidence(error),
              evidence: %{symbol: sample.symbol}
            ),
          value: nil
        }
    end
  end

  defp collect_balances(exchange, environment, observed_at, request_opts) do
    case Bourse.fetch_balance(exchange, request_opts) do
      {:ok, balance} ->
        Cell.new(:balances,
          outcome: :ok,
          observed_at: observed_at,
          environment: environment,
          summary: "balance currencies=#{map_size(balance.total || %{})}",
          evidence: %{
            currency_count: map_size(balance.total || %{}),
            timestamp: balance.timestamp
          }
        )

      {:error, %Error{} = error} ->
        Cell.new(:balances,
          outcome: :error,
          observed_at: observed_at,
          environment: environment,
          summary: error.message,
          error: error_evidence(error)
        )
    end
  end

  defp collect_positions(exchange, environment, observed_at, request_opts) do
    case Bourse.fetch_positions(exchange, request_opts) do
      {:ok, positions} when is_list(positions) ->
        count = length(positions)

        Cell.new(:positions,
          outcome: :ok,
          observed_at: observed_at,
          environment: environment,
          summary: "positions=#{count}",
          evidence: %{count: count}
        )

      {:error, %Error{} = error} ->
        Cell.new(:positions,
          outcome: :error,
          observed_at: observed_at,
          environment: environment,
          summary: error.message,
          error: error_evidence(error)
        )
    end
  end

  defp collect_open_orders(exchange, environment, observed_at, request_opts) do
    case Bourse.fetch_open_orders(exchange, request_opts) do
      {:ok, orders} when is_list(orders) ->
        count = length(orders)

        Cell.new(:open_orders,
          outcome: :ok,
          observed_at: observed_at,
          environment: environment,
          summary: "open_orders=#{count}",
          evidence: %{count: count}
        )

      {:error, %Error{} = error} ->
        Cell.new(:open_orders,
          outcome: :error,
          observed_at: observed_at,
          environment: environment,
          summary: error.message,
          error: error_evidence(error)
        )
    end
  end

  defp collect_lifecycle(_exchange, _instruments, environment, observed_at, _request_opts, false) do
    Cell.new(:create_fetch_cancel,
      outcome: :untested,
      observed_at: observed_at,
      environment: environment,
      summary: "lifecycle mutation skipped (pass mutate: true to exercise)"
    )
  end

  defp collect_lifecycle(exchange, instruments, environment, observed_at, request_opts, true) do
    case pick_lifecycle_instrument(instruments) do
      nil ->
        Cell.new(:create_fetch_cancel,
          outcome: :empty,
          observed_at: observed_at,
          environment: environment,
          summary: "no option instrument available for lifecycle"
        )

      instrument ->
        run_lifecycle(exchange, instrument, environment, observed_at, request_opts)
    end
  end

  defp run_lifecycle(exchange, instrument, environment, observed_at, request_opts) do
    symbol = instrument.symbol
    market = find_market(exchange, symbol)
    amount = lifecycle_amount(exchange, symbol)
    price = lifecycle_price(instrument, market)

    client_order_id = "opt-ready-#{observed_at}-#{System.unique_integer([:positive])}"

    create_opts =
      request_opts
      |> Keyword.put(:price, price)
      |> Keyword.put(:clientOrderId, client_order_id)
      |> Keyword.put(:postOnly, true)
      |> maybe_venue_lifecycle_opts(exchange)

    case Bourse.create_order(exchange, symbol, "limit", "buy", amount, create_opts) do
      {:ok, %Order{id: order_id} = created} when is_binary(order_id) ->
        created_at = System.system_time(:millisecond)
        transient_submission? = transient_submission?(created)
        {fetch_result, fetch_path} = read_back_order(exchange, order_id, symbol, request_opts)
        fetched_at = System.system_time(:millisecond)
        cancel_result = Bourse.cancel_order(exchange, order_id, Keyword.put(request_opts, :symbol, symbol))
        cancelled_at = System.system_time(:millisecond)
        reconciliation = reconcile_cancel_race(exchange, order_id, symbol, request_opts, cancel_result)
        {residual_result, residual_count} = residual_open_orders(exchange, order_id, symbol, request_opts)
        residual_at = System.system_time(:millisecond)

        outcome = lifecycle_outcome(fetch_result, cancel_result, residual_result, fetch_path, transient_submission?)

        Cell.new(:create_fetch_cancel,
          outcome: outcome,
          observed_at: observed_at,
          environment: environment,
          summary: lifecycle_summary(outcome, symbol),
          evidence:
            put_reconciliation(
              %{
                symbol: symbol,
                order_id: order_id,
                client_order_id: client_order_id,
                read_back_path: fetch_path,
                transient_submission: transient_submission?,
                create: timed_result_summary({:ok, created}, created_at),
                fetch: timed_result_summary(fetch_result, fetched_at),
                cancel: timed_result_summary(cancel_result, cancelled_at),
                residual_open_orders:
                  timed_result_summary(residual_result_to_summary(residual_result, residual_count), residual_at)
              },
              reconciliation
            ),
          error:
            if(outcome == :error,
              do: %{
                fetch: result_summary(fetch_result),
                cancel: result_summary(cancel_result),
                residual_open_orders: residual_count
              }
            )
        )

      {:error, %Error{raw: %{venue: _venue, field: _field, raw_value: _raw_value}} = error} ->
        failed_at = System.system_time(:millisecond)

        Cell.new(:create_fetch_cancel,
          outcome: :blocked,
          observed_at: observed_at,
          environment: environment,
          summary: "order submission status requires reconciliation before any resubmission",
          evidence: %{
            symbol: symbol,
            amount: amount,
            price: price,
            create: timed_result_summary({:error, error}, failed_at)
          }
        )

      {:error, %Error{} = error} ->
        failed_at = System.system_time(:millisecond)

        Cell.new(:create_fetch_cancel,
          outcome: :error,
          observed_at: observed_at,
          environment: environment,
          summary: error.message,
          error: error_evidence(error),
          evidence: %{
            symbol: symbol,
            amount: amount,
            price: price,
            create: timed_result_summary({:error, error}, failed_at)
          }
        )
    end
  end

  defp transient_submission?(%Order{info: %{"order_state" => state}})
       when state in ["speed_bumped", "triggered", "untriggered"], do: true

  defp transient_submission?(%Order{status: status})
       when is_binary(status) and
              status not in ["open", "closed", "filled", "canceled", "cancelled", "rejected", "failed"], do: true

  defp transient_submission?(%Order{}), do: false

  defp reconcile_cancel_race(exchange, order_id, symbol, request_opts, {:error, %Error{code: code}})
       when code in [11_044, "11044"] do
    observed_at = System.system_time(:millisecond)
    {result, path} = read_back_order(exchange, order_id, symbol, request_opts)
    %{path: path, result: timed_result_summary(result, observed_at)}
  end

  defp reconcile_cancel_race(_exchange, _order_id, _symbol, _request_opts, _cancel_result), do: nil

  defp lifecycle_outcome(fetch_result, cancel_result, residual_result, fetch_path, transient_submission?) do
    cond do
      lifecycle_ok?(fetch_result, cancel_result, residual_result, fetch_path) -> :ok
      transient_submission? -> :blocked
      cancel_not_open?(cancel_result) -> :blocked
      true -> :error
    end
  end

  defp cancel_not_open?({:error, %Error{code: code}}), do: code in [11_044, "11044"]
  defp cancel_not_open?(_cancel_result), do: false

  defp lifecycle_summary(:blocked, symbol),
    do: "submission remains live pending order-history reconciliation on #{symbol}"

  defp lifecycle_summary(_outcome, symbol), do: "create/fetch/cancel on #{symbol}"

  defp put_reconciliation(evidence, nil), do: evidence
  defp put_reconciliation(evidence, reconciliation), do: Map.put(evidence, :reconciliation, reconciliation)

  # Prefer fetch_order when the venue supports it; derive and similar venues expose
  # only open-order list reads for resting lifecycle attestation.
  defp read_back_order(exchange, order_id, symbol, request_opts) do
    symbol_opts = Keyword.put(request_opts, :symbol, symbol)

    if Exchange.has?(exchange, "fetchOrder") do
      {Bourse.fetch_order(exchange, order_id, symbol_opts), :fetch_order}
    else
      {find_open_order(exchange, order_id, symbol_opts), :fetch_open_orders}
    end
  end

  defp find_open_order(exchange, order_id, request_opts) do
    case Bourse.fetch_open_orders(exchange, request_opts) do
      {:ok, orders} when is_list(orders) ->
        case Enum.find(orders, &(is_map(&1) and Map.get(&1, :id) == order_id)) do
          %Order{} = order ->
            {:ok, order}

          nil ->
            {:error,
             Error.order_not_found(
               message: "order #{order_id} not present in fetch_open_orders after create",
               exchange: exchange.id
             )}
        end

      {:error, %Error{}} = error ->
        error

      other ->
        {:error,
         Error.operation_failed(
           message: "fetch_open_orders returned unexpected shape: #{inspect(other)}",
           exchange: exchange.id
         )}
    end
  end

  defp residual_open_orders(exchange, order_id, symbol, request_opts) do
    symbol_opts = Keyword.put(request_opts, :symbol, symbol)

    case Bourse.fetch_open_orders(exchange, symbol_opts) do
      {:ok, orders} when is_list(orders) ->
        residual =
          Enum.count(orders, fn
            %Order{id: ^order_id} -> true
            %{id: ^order_id} -> true
            _ -> false
          end)

        {{:ok, residual}, residual}

      {:error, %Error{}} = error ->
        {error, nil}

      other ->
        {{:error,
          Error.operation_failed(
            message: "fetch_open_orders residual check returned unexpected shape: #{inspect(other)}",
            exchange: exchange.id
          )}, nil}
    end
  end

  defp lifecycle_ok?(fetch_result, cancel_result, residual_result, fetch_path) do
    case {fetch_result, cancel_result, residual_result, fetch_path} do
      {{:ok, _fetched}, {:ok, _cancelled}, {:ok, 0}, _path} ->
        true

      # When fetch_order is the venue-native read-back, residual open-order
      # attestation is best-effort (network blip must not mask a good cancel).
      {{:ok, _fetched}, {:ok, _cancelled}, {:error, _reason}, :fetch_order} ->
        true

      # Still-resting orders always fail; open_orders-only venues (derive) must
      # prove zero residual.
      _other ->
        false
    end
  end

  defp residual_result_to_summary({:ok, count}, _count) when is_integer(count), do: {:ok, %{count: count}}
  defp residual_result_to_summary({:error, %Error{}} = error, _count), do: error
  defp residual_result_to_summary(_other, count), do: {:ok, %{count: count}}

  defp collect_preflight_and_hedge(exchange, instruments, greeks_cell, environment, observed_at, request_opts, opts) do
    case build_proposal(exchange, instruments, greeks_cell, request_opts) do
      {:ok, proposal} ->
        run_preflight(proposal, environment, opts)

      {:skip, reason} ->
        skipped_preflight_cells(reason, environment, observed_at)
    end
  end

  defp run_preflight(proposal, environment, opts) do
    max_age_ms = Keyword.get(opts, :max_age_ms, @default_max_age_ms)
    evaluated_at = System.system_time(:millisecond)

    case OptionProposal.preflight(proposal, observed_at: evaluated_at, max_age_ms: max_age_ms) do
      {:ok, result} -> successful_preflight_cells(result, environment, evaluated_at)
      {:error, %Error{} = error} -> failed_preflight_cells(error, environment, evaluated_at)
    end
  end

  defp successful_preflight_cells(result, environment, evaluated_at) do
    preflight =
      Cell.new(:preflight,
        outcome: :ok,
        observed_at: evaluated_at,
        environment: environment,
        summary: "preflight #{result.status}",
        evidence: %{
          evaluated_at: evaluated_at,
          status: result.status,
          violations: Enum.map(result.violations, & &1.code),
          checks: Enum.map(result.checks, &Map.take(&1, [:name, :status])),
          failures: Enum.map(result.failures, &inspect/1)
        }
      )

    {preflight, hedge_cell(result.hedge, environment, evaluated_at)}
  end

  defp hedge_cell(%{feasible?: true, quantity: quantity} = hedge, environment, observed_at) when is_number(quantity) do
    Cell.new(:hedge,
      outcome: :ok,
      observed_at: observed_at,
      environment: environment,
      summary: "hedge quantity=#{quantity}",
      evidence: %{
        quantity: quantity,
        feasible: true,
        side: Map.get(hedge, :side),
        residual_delta: Map.get(hedge, :residual_delta),
        candidate_id: Map.get(hedge, :candidate_id)
      }
    )
  end

  defp hedge_cell(%{feasible?: false} = hedge, environment, observed_at) do
    Cell.new(:hedge,
      outcome: :blocked,
      observed_at: observed_at,
      environment: environment,
      summary: "hedge infeasible: #{inspect(Map.get(hedge, :reason))}",
      evidence: %{
        feasible: false,
        reason: inspect(Map.get(hedge, :reason)),
        residual_delta: Map.get(hedge, :residual_delta),
        candidate_id: Map.get(hedge, :candidate_id)
      }
    )
  end

  defp hedge_cell(_hedge, environment, observed_at) do
    Cell.new(:hedge,
      outcome: :empty,
      observed_at: observed_at,
      environment: environment,
      summary: "no hedge sized"
    )
  end

  defp failed_preflight_cells(error, environment, observed_at) do
    {
      Cell.new(:preflight,
        outcome: :error,
        observed_at: observed_at,
        environment: environment,
        summary: error.message,
        error: error_evidence(error)
      ),
      Cell.new(:hedge,
        outcome: :untested,
        observed_at: observed_at,
        environment: environment,
        summary: "hedge not run because preflight failed"
      )
    }
  end

  defp skipped_preflight_cells(reason, environment, observed_at) do
    {
      Cell.new(:preflight,
        outcome: :skipped,
        observed_at: observed_at,
        environment: environment,
        summary: reason
      ),
      Cell.new(:hedge,
        outcome: :skipped,
        observed_at: observed_at,
        environment: environment,
        summary: reason
      )
    }
  end

  defp build_proposal(
         exchange,
         instruments,
         %{cell: %Cell{outcome: :ok}, value: %InstrumentGreeks{} = greeks},
         request_opts
       ) do
    case pick_sample(instruments) do
      nil ->
        {:skip, "no instruments for preflight"}

      instrument ->
        case complete_greeks_for_preflight(exchange, greeks, instrument, request_opts) do
          {:ok, completed} ->
            market = find_market(exchange, instrument.symbol)
            amount = lifecycle_amount(exchange, instrument.symbol)
            price = lifecycle_price(instrument)
            source_ts = completed.source_timestamp
            hedge_candidate = hedge_candidate_for(exchange, instrument, request_opts)
            observed_at = instrument.observed_at || System.system_time(:millisecond)

            {:ok,
             %{
               legs: [
                 %{
                   id: "option-leg",
                   venue: exchange.id,
                   account: "readiness",
                   symbol: instrument.symbol,
                   side: "buy",
                   amount: amount,
                   price: price,
                   type: "limit",
                   market: market,
                   greeks: completed,
                   exchange: exchange,
                   quote: %{
                     bid: instrument.bid_price,
                     ask: instrument.ask_price,
                     timestamp: source_ts,
                     observed_at: observed_at,
                     source_timestamp: source_ts
                   },
                   market_observed_at: observed_at
                 }
               ],
               hedge_candidates: List.wrap(hedge_candidate),
               risk_targets: %{delta: 0.0},
               hard_limits: %{residual_delta_abs: 1.0, delta: %{max_abs: 10.0}},
               venue_policy: :same_only,
               scopes: [PortfolioRisk.scope(exchange, "readiness", request_opts)]
             }}

          {:skip, reason} ->
            {:skip, reason}
        end
    end
  end

  defp build_proposal(_exchange, _instruments, _greeks, _request_opts) do
    {:skip, "greeks cell not ok; preflight skipped"}
  end

  # Completes missing preflight inputs from live venue data only — never invents
  # Greeks numbers, prices, or provider timestamps. Core Greeks
  # (delta/gamma/theta/vega) and their source_timestamp must already be present;
  # underlying_price may be filled from tickers.
  defp complete_greeks_for_preflight(exchange, greeks, instrument, request_opts) do
    missing = missing_core_greeks(greeks)

    cond do
      complete_greeks?(greeks) -> {:ok, greeks}
      missing != [] -> {:skip, missing_core_greeks_reason(missing)}
      true -> complete_greeks_from_live_tickers(exchange, greeks, instrument, request_opts)
    end
  end

  defp missing_core_greeks_reason(missing) do
    "complete option Greeks unavailable for preflight (missing #{Enum.join(missing, ", ")})"
  end

  defp complete_greeks_from_live_tickers(exchange, greeks, instrument, request_opts) do
    completed = fill_greeks_from_live_tickers(exchange, greeks, instrument, request_opts)

    if complete_greeks?(completed) do
      {:ok, completed}
    else
      {:skip, incomplete_greeks_reason(completed)}
    end
  end

  defp fill_greeks_from_live_tickers(exchange, greeks, instrument, request_opts) do
    exchange
    |> live_price_sources(instrument)
    |> Enum.reduce(greeks, &fill_greeks_from_live_ticker(exchange, request_opts, &1, &2))
  end

  defp fill_greeks_from_live_ticker(exchange, request_opts, {symbol, role}, greeks) do
    if complete_greeks?(greeks) do
      greeks
    else
      merge_greeks_from_ticker_result(greeks, Bourse.fetch_ticker(exchange, symbol, request_opts), role)
    end
  end

  defp merge_greeks_from_ticker_result(greeks, {:ok, %Ticker{} = ticker}, role),
    do: merge_greeks_from_ticker(greeks, ticker, role)

  defp merge_greeks_from_ticker_result(greeks, _result, _role), do: greeks

  defp live_price_sources(exchange, instrument) do
    hedge = pick_hedge_market(exchange, instrument)

    [{instrument.symbol, :option} | List.wrap(hedge && {hedge.symbol, :underlying})]
    |> Enum.reject(fn {symbol, _role} -> is_nil(symbol) end)
    |> Enum.uniq_by(fn {symbol, _role} -> symbol end)
  end

  defp merge_greeks_from_ticker(%InstrumentGreeks{} = greeks, %Ticker{} = ticker, role) do
    %{greeks | underlying_price: greeks.underlying_price || ticker_underlying_price(ticker, role)}
  end

  # Option tickers: only index / explicit underlying fields — mark/last are premiums.
  # Underlying (perp/spot) tickers: full price ladder is valid.
  defp ticker_underlying_price(%Ticker{} = ticker, :option) do
    positive_number(ticker.index_price) || underlying_from_info(ticker.info)
  end

  defp ticker_underlying_price(%Ticker{} = ticker, :underlying) do
    Enum.find_value(
      [ticker.index_price, ticker.mark_price, ticker.last, ticker.close, ticker.bid, ticker.ask],
      &positive_number/1
    ) || underlying_from_info(ticker.info)
  end

  defp underlying_from_info(info) when is_map(info) do
    Enum.find_value(
      ["underlyingPrice", "underlying_price", "indexPrice", "index_price", "fwdPx", "idxPx"],
      fn key ->
        case Map.get(info, key) do
          value when is_number(value) and value > 0 -> value
          value when is_binary(value) -> parse_float(value)
          _ -> nil
        end
      end
    )
  end

  defp underlying_from_info(_info), do: nil

  defp parse_float(value) do
    case Float.parse(value) do
      {num, ""} when num > 0 -> num
      _ -> nil
    end
  end

  defp positive_number(value) when is_number(value) and value > 0, do: value
  defp positive_number(_value), do: nil

  defp missing_core_greeks(greeks) do
    Enum.reject([:delta, :gamma, :theta, :vega], &is_number(Map.get(greeks, &1)))
  end

  defp incomplete_greeks_reason(greeks) do
    missing =
      []
      |> then(fn acc -> if is_number(greeks.underlying_price), do: acc, else: ["underlying_price" | acc] end)
      |> then(fn acc -> if is_integer(greeks.source_timestamp), do: acc, else: ["source_timestamp" | acc] end)
      |> Enum.reverse()

    "complete option Greeks and underlying price unavailable for preflight (missing #{Enum.join(missing, ", ")}; live ticker completion attempted)"
  end

  defp hedge_candidate_for(exchange, instrument, request_opts) do
    case pick_hedge_market(exchange, instrument) do
      %Market{} = market ->
        {price, quote} = live_hedge_price(exchange, market.symbol, request_opts)

        %{
          id: "same-hedge",
          venue: exchange.id,
          account: "readiness",
          symbol: market.symbol,
          market: market,
          exchange: exchange,
          market_observed_at: System.system_time(:millisecond),
          request_opts: request_opts
        }
        |> maybe_put(:price, price)
        |> maybe_put(:quote, quote)

      nil ->
        nil
    end
  end

  defp pick_hedge_market(%Exchange{markets: markets}, instrument) when is_list(markets) do
    base = instrument.base
    settle = instrument.settle

    candidates =
      Enum.filter(markets, fn
        %Market{swap: true, base: ^base, active: active} when active != false -> true
        %Market{type: "swap", base: ^base, active: active} when active != false -> true
        _ -> false
      end)

    candidates
    |> Enum.sort_by(fn market ->
      {
        if(usable_contract_multiplier?(market), do: 0, else: 1),
        if(settle && market.settle == settle, do: 0, else: 1),
        if(market.inverse == true, do: 0, else: 1),
        market.symbol || ""
      }
    end)
    |> List.first()
  end

  defp pick_hedge_market(_exchange, _instrument), do: nil

  defp usable_contract_multiplier?(%Market{spot: true}), do: true

  defp usable_contract_multiplier?(%Market{contract_size: size}) when is_number(size) and size > 0, do: true

  defp usable_contract_multiplier?(%Market{contract: true}), do: false

  defp usable_contract_multiplier?(%Market{}), do: true

  defp live_hedge_price(exchange, symbol, request_opts) do
    case Bourse.fetch_ticker(exchange, symbol, request_opts) do
      {:ok, %Ticker{} = ticker} ->
        price = ticker_trade_price(ticker)
        quote = ticker_quote_map(ticker)
        {price, quote}

      _other ->
        {nil, nil}
    end
  end

  defp ticker_trade_price(%Ticker{} = ticker) do
    Enum.find_value(
      [ticker.mark_price, ticker.index_price, ticker.last, ticker.close, ticker.bid, ticker.ask],
      &positive_number/1
    )
  end

  defp ticker_quote_map(%Ticker{} = ticker) do
    %{
      mark_price: ticker.mark_price,
      index_price: ticker.index_price,
      last: ticker.last,
      price: ticker.last,
      timestamp: ticker.timestamp
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp observe_book(%{cell: %Cell{outcome: outcome}, instruments: instruments}, observed_at)
       when outcome in [:ok, :empty] do
    two_sided =
      Enum.filter(instruments, fn i ->
        is_number(i.bid_price) and i.bid_price > 0 and is_number(i.ask_price) and i.ask_price > 0
      end)

    %{
      observed: true,
      observed_at: observed_at,
      instrument_count: length(instruments),
      two_sided_count: length(two_sided),
      two_sided: two_sided != [],
      empty: instruments == [] or two_sided == [],
      sample:
        instruments
        |> Enum.take(3)
        |> Enum.map(fn i ->
          %{symbol: i.symbol, bid: i.bid_price, ask: i.ask_price}
        end)
    }
  end

  defp observe_book(%{instruments: instruments}, observed_at) do
    %{
      observed: false,
      observed_at: observed_at,
      instrument_count: length(instruments),
      two_sided_count: 0,
      two_sided: nil,
      empty: nil,
      sample: []
    }
  end

  defp book_limitation(%{observed: true, empty: true, observed_at: observed_at} = book) do
    %{
      kind: :market_unavailable,
      observed_at: observed_at,
      detail: "empty or one-sided option book",
      book: book
    }
  end

  defp book_limitation(_book), do: nil

  defp complete_greeks?(greeks) do
    Enum.all?([:delta, :gamma, :theta, :vega, :underlying_price], &is_number(Map.get(greeks, &1))) and
      is_integer(greeks.source_timestamp)
  end

  defp discovery_instruments(%{instruments: instruments}), do: instruments

  defp pick_sample([]), do: nil
  defp pick_sample(instruments), do: Enum.find(instruments, &(&1.option_type in ["call", "C"])) || hd(instruments)

  defp pick_lifecycle_instrument(instruments) do
    Enum.find(instruments, fn i ->
      is_number(i.ask_price) and i.ask_price > 0
    end) || pick_sample(instruments)
  end

  defp lifecycle_amount(exchange, symbol) do
    market = find_market(exchange, symbol)
    step = amount_step(market)
    min_amount = market_min_amount(market)

    [step, min_amount]
    |> Enum.filter(&(is_number(&1) and &1 > 0))
    |> case do
      [] -> 0.1
      values -> Enum.max(values)
    end
  end

  defp amount_step(%Market{native_amount_step: step}) when is_number(step) and step > 0, do: step
  defp amount_step(%Market{precision: %{"amount" => step}}) when is_number(step) and step > 0, do: step
  defp amount_step(%Market{precision: %{amount: step}}) when is_number(step) and step > 0, do: step
  defp amount_step(_market), do: nil

  defp market_min_amount(%Market{limits: %{"amount" => %{"min" => min}}}) when is_number(min), do: min
  defp market_min_amount(%Market{limits: %{amount: %{min: min}}}) when is_number(min), do: min

  defp market_min_amount(%Market{info: info}) when is_map(info) do
    case Map.get(info, "minimum_amount") || Map.get(info, "min_amount") do
      value when is_number(value) and value > 0 -> value
      value when is_binary(value) -> parse_float(value)
      _ -> nil
    end
  end

  defp market_min_amount(_market), do: nil

  # Far-from-market buy limit: half the best bid/ask when quoted, else the venue
  # minimum price (still far when the book is empty / one-sided).
  defp lifecycle_price(instrument, market \\ nil) do
    instrument
    |> far_from_market_price()
    |> choose_lifecycle_price(market_min_price(market))
  end

  defp far_from_market_price(%{bid_price: bid}) when is_number(bid) and bid > 0, do: bid * 0.5
  defp far_from_market_price(%{ask_price: ask}) when is_number(ask) and ask > 0, do: ask * 0.5
  defp far_from_market_price(_instrument), do: nil

  defp choose_lifecycle_price(raw, minimum) when is_number(raw) and is_number(minimum), do: max(raw, minimum)
  defp choose_lifecycle_price(raw, _minimum) when is_number(raw), do: raw
  defp choose_lifecycle_price(_raw, minimum) when is_number(minimum), do: minimum
  defp choose_lifecycle_price(_raw, _minimum), do: @default_lifecycle_price

  defp market_min_price(%Market{limits: %{"price" => %{"min" => min}}}) when is_number(min) and min > 0, do: min
  defp market_min_price(%Market{limits: %{price: %{min: min}}}) when is_number(min) and min > 0, do: min
  defp market_min_price(%Market{precision: %{"price" => step}}) when is_number(step) and step > 0, do: step

  defp market_min_price(%Market{info: info}) when is_map(info) do
    case Map.get(info, "tick_size") || Map.get(info, "price_step") || Map.get(info, "minimum_price") do
      value when is_number(value) and value > 0 -> value
      value when is_binary(value) -> parse_float(value)
      _ -> nil
    end
  end

  defp market_min_price(_market), do: nil

  # Derive requires a signed max_fee on every order (venue dynamic floor; use a
  # generous readiness ceiling so far-from-market limits still accept). Demo books
  # also reject sub-0.1 limit prices on option instruments (pinned live 2026-07-23).
  defp maybe_venue_lifecycle_opts(opts, %Exchange{id: "derive"}) do
    opts
    |> Keyword.put_new(:max_fee, @derive_readiness_max_fee)
    |> Keyword.update(:price, @derive_min_option_price, fn
      price when is_number(price) and price < @derive_min_option_price -> @derive_min_option_price
      price -> price
    end)
  end

  defp maybe_venue_lifecycle_opts(opts, _exchange), do: opts

  defp find_market(%Exchange{markets: markets}, symbol) when is_list(markets) do
    Enum.find(markets, &(&1.symbol == symbol))
  end

  defp find_market(_exchange, _symbol), do: nil

  defp maybe_load_markets(%Exchange{markets: markets} = exchange, _request_opts) when is_list(markets) and markets != [],
    do: exchange

  defp maybe_load_markets(exchange, request_opts) do
    case Bourse.load_markets(exchange, request_opts) do
      {:ok, loaded} -> loaded
      _other -> exchange
    end
  end

  defp error_evidence(%Error{} = error) do
    %{
      type: error.type,
      message: error.message,
      code: error.code,
      exchange: error.exchange
    }
  end

  defp result_summary({:ok, %Order{} = order}), do: %{ok: true, id: order.id, status: order.status}
  defp result_summary({:ok, other}), do: %{ok: true, value: inspect(other)}
  defp result_summary({:error, %Error{} = error}), do: %{ok: false, error: error_evidence(error)}
  defp result_summary(other), do: %{ok: false, value: inspect(other)}

  defp timed_result_summary(result, observed_at) do
    result
    |> result_summary()
    |> Map.put(:observed_at, observed_at)
  end
end
