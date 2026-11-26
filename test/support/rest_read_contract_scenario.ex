defmodule Bourse.Test.RestReadContractScenario do
  @moduledoc """
  Executes and asserts provider-live REST-read scenarios.

  All judgments are supplied by the inventory. These functions only resolve
  its mechanical strategies, perform real Bourse calls, and enforce the stated
  success and error meanings.
  """

  import ExUnit.Assertions

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.LiveLane.Ledger
  alias Bourse.RawResponse
  alias Bourse.Test.RestReadContractOwnedState
  alias Bourse.Test.RestReadContracts
  alias Bourse.Testnet
  alias Bourse.Unified

  @auth_deadline_seconds 300

  @typedoc "Live state shared by all provider branches for one venue."
  @type context :: %{
          exchange: Exchange.t(),
          markets: [map()],
          venue: String.t(),
          venue_contract: map()
        }

  @doc "Builds the live venue context used by that venue's contract cases."
  @spec setup_venue!(String.t() | atom()) :: context()
  def setup_venue!(venue) do
    venue = to_string(venue)
    venue_contract = RestReadContracts.inventory()["venues"][venue]
    exchange = venue |> live_exchange!(venue_contract) |> loaded_exchange!(venue)

    %{
      exchange: exchange,
      markets: exchange.markets || [],
      venue: venue,
      venue_contract: venue_contract
    }
  end

  @doc "Performs one inventoried provider branch and asserts its domain meaning."
  @spec assert_case!(map(), context()) :: :ok
  def assert_case!(%{"kind" => "error"} = contract_case, context) do
    method = existing_method_atom!(contract_case["method"])
    {args, resolved} = resolve_arguments!(contract_case, context)
    opts = case_options(contract_case, context, resolved)
    result = apply(Bourse, method, [context.exchange | args] ++ [opts])
    assert_observed_error!(result, contract_case)
  end

  def assert_case!(contract_case, context) do
    contract_case = with_selected_option(contract_case, context)
    method = existing_method_atom!(contract_case["method"])
    {args, resolved} = resolve_arguments!(contract_case, context)
    opts = case_options(contract_case, context, resolved)
    result = apply(Bourse, method, [context.exchange | args] ++ [opts])
    assert_success!(contract_case, result, resolved)
  rescue
    confirmed in [Ledger.ErrorConfirmed] ->
      Ledger.record(confirmed)
      :ok

    error in [ExUnit.AssertionError, ArgumentError] ->
      reraise error, __STACKTRACE__

    # The catch-all is deliberate: any other raise during contract assertion is
    # itself evidence, to be reported via flunk rather than hidden.
    # reach:disable-next-line bare_rescue
    error ->
      flunk(
        "#{contract_case["id"]} raised before proving provider semantics: #{Exception.format(:error, error, __STACKTRACE__)}"
      )
  end

  @doc "Asserts inventoried success meaning against an already-observed value."
  @spec assert_live_value!(map(), term()) :: :ok
  def assert_live_value!(contract_case, value) do
    assert_success!(contract_case, {:ok, value}, %{})
  end

  defp loaded_exchange!(exchange, venue) do
    case Bourse.load_markets(exchange) do
      {:ok, loaded} ->
        loaded

      {:error, %Error{type: :not_supported}} ->
        exchange

      {:error, reason} ->
        flunk("#{venue}: load_markets failed before REST-read contracts could run: #{format_reason(reason)}")
    end
  end

  defp live_exchange!("coinbaseexchange", _contract), do: Exchange.new!(:coinbaseexchange)

  defp live_exchange!(venue, contract) do
    venue_atom = String.to_existing_atom(venue)

    case Testnet.creds(venue_atom, :default) do
      %Bourse.Credentials{} = credentials ->
        Exchange.new!(venue_atom, credentials: credentials, sandbox: true)

      nil ->
        flunk(missing_credentials_message(venue, contract["credentials"]))
    end
  end

  defp missing_credentials_message(venue, credentials) do
    exports = Enum.map_join(credentials["exports"], "\n", &~s(  export #{&1}="your_value"))

    """
    Missing provider-live credentials for #{venue}.

    Set these environment variables and re-run `mix bourse.verify_rest_read_contracts`:
    #{exports}

    Get credentials at: #{credentials["url"]}
    """
  end

  defp assert_observed_error!(result, contract_case) do
    contract = contract_case["expected_error"]

    case result do
      {:error, %Error{} = error} ->
        assert Atom.to_string(error.type) == contract["type"], error_message(contract_case, error)
        assert error.code == contract["code"], error_message(contract_case, error)
        assert error.message =~ contract["message_contains"], error_message(contract_case, error)
        :ok

      other ->
        flunk("#{contract_case["id"]}: expected provider error #{inspect(contract)}, got #{inspect(other)}")
    end
  end

  defp error_message(contract_case, actual) do
    "#{contract_case["id"]}: provider error meaning drifted; " <>
      "expected #{inspect(contract_case["expected_error"])}, got #{inspect(actual)}"
  end

  defp resolve_arguments!(contract_case, context) do
    resolved =
      Map.new(contract_case["arguments"], fn argument ->
        {argument["name"], resolve_argument!(argument, contract_case, context)}
      end)

    args = Enum.map(contract_case["arguments"], &Map.fetch!(resolved, &1["name"]))
    {args, resolved}
  end

  defp resolve_argument!(%{"strategy" => "market_symbol"}, contract_case, context),
    do: market_symbol!(context, contract_case)

  defp resolve_argument!(%{"strategy" => "market_type"}, contract_case, _context), do: contract_case["market_kind"]

  defp resolve_argument!(%{"strategy" => "market_sub_type"}, contract_case, _context),
    do: if(contract_case["market_kind"] == "inverse", do: "inverse", else: "linear")

  defp resolve_argument!(%{"strategy" => "venue_currency"}, _contract_case, context),
    do: context.venue_contract["currency"]

  defp resolve_argument!(%{"strategy" => "credential_uid"}, _contract_case, context), do: context.exchange.credentials.uid

  defp resolve_argument!(%{"strategy" => "literal", "value" => value}, _contract_case, _context), do: value

  defp resolve_argument!(%{"strategy" => "resource"} = argument, contract_case, context),
    do: resource_value!(argument, contract_case, context)

  defp resolve_argument!(argument, contract_case, _context) do
    flunk("#{contract_case["id"]}: unknown argument strategy #{inspect(argument)}")
  end

  defp case_options(contract_case, context, resolved) do
    options =
      Enum.map(contract_case["options"], fn option ->
        {option_atom!(option["name"], contract_case), option_value!(option, contract_case, context)}
      end)

    options
    |> Keyword.put(:endpoint_index, contract_case["endpoint_index"])
    |> maybe_put_resolved_symbol(resolved)
  end

  # The closed set of inventoried option names. Venue-specific keys such as
  # :baseCoin exist nowhere in compiled code, so String.to_existing_atom/1
  # rejects valid cases; an open String.to_atom/1 is not acceptable either.
  # A new inventory option name must be added here, or the case fails loudly.
  @option_atoms %{
    "account_index" => :account_index,
    "auth_deadline" => :auth_deadline,
    "baseCoin" => :baseCoin,
    "category" => :category,
    "code" => :code,
    "currency" => :currency,
    "instFamily" => :instFamily,
    "instType" => :instType,
    "l1_address" => :l1_address,
    "limit" => :limit,
    "loc" => :loc,
    "pair" => :pair,
    "start_timestamp" => :start_timestamp,
    "startTime" => :startTime,
    "subaccount_id" => :subaccount_id,
    "symbol" => :symbol,
    "timestamp_ms_override" => :timestamp_ms_override,
    "type" => :type,
    "user" => :user
  }

  defp option_atom!(name, contract_case) do
    @option_atoms[name] ||
      flunk(
        "#{contract_case["id"]}: inventory option #{inspect(name)} is not in the scenario's " <>
          "@option_atoms map; add it to Bourse.Test.RestReadContractScenario"
      )
  end

  defp option_value!(%{"strategy" => "market_symbol"}, contract_case, context), do: market_symbol!(context, contract_case)

  defp option_value!(%{"strategy" => "market_type"}, contract_case, _context), do: contract_case["market_kind"]
  defp option_value!(%{"strategy" => "venue_currency"}, _contract_case, context), do: context.venue_contract["currency"]
  defp option_value!(%{"strategy" => "credential_uid"}, _contract_case, context), do: credential_uid!(context)

  defp option_value!(%{"strategy" => "credential_api_key"}, _contract_case, context),
    do: context.exchange.credentials.api_key

  defp option_value!(%{"strategy" => "auth_deadline"}, _contract_case, _context),
    do: System.system_time(:second) + @auth_deadline_seconds

  defp option_value!(%{"strategy" => "current_time_ms"}, _contract_case, _context), do: System.system_time(:millisecond)
  defp option_value!(%{"strategy" => "literal", "value" => value}, _contract_case, _context), do: value

  defp option_value!(%{"strategy" => "selection_base"}, %{"selection_base" => base}, _context), do: base

  # Per-credential values the venue publishes about the live account (e.g.
  # lighter's l1_address) resolve through the same live resource machinery
  # the argument strategies use — never through an operator-specific literal.
  defp option_value!(%{"strategy" => "resource"} = option, contract_case, context),
    do: resource_value!(option, contract_case, context)

  defp maybe_put_resolved_symbol(options, %{"symbol" => symbol}), do: Keyword.put_new(options, :symbol, symbol)
  defp maybe_put_resolved_symbol(options, _resolved), do: options

  defp credential_uid!(%{exchange: %{credentials: %{uid: uid}}}) when is_binary(uid), do: String.to_integer(uid)

  defp credential_uid!(%{venue: "derive"}), do: flunk(Bourse.Test.DeriveAccount.setup_message())

  defp credential_uid!(context),
    do: flunk("#{context.venue}: provider contract requires a numeric credential account index")

  defp market_symbol!(_context, %{"selected_option" => %{symbol: symbol}}), do: symbol

  defp market_symbol!(_context, %{"symbol" => symbol}) when is_binary(symbol) and symbol != "", do: symbol

  defp market_symbol!(context, %{"market_kind" => "option"} = contract_case) do
    flunk(
      "#{contract_case["id"]}: option branch reached symbol resolution without an option_instrument " <>
        "selection on #{context.venue}; declare option_instrument on the branch"
    )
  end

  defp market_symbol!(%{markets: []} = context, contract_case) do
    kind = contract_case["market_kind"]

    context.venue_contract["symbols"][kind] || context.venue_contract["symbols"]["spot"] ||
      flunk("#{context.venue}: provider contract has no live symbol strategy")
  end

  defp market_symbol!(context, contract_case) do
    kind = contract_case["market_kind"]
    candidates = Enum.filter(context.markets, &market_kind?(&1, kind))
    preferred = context.venue_contract["symbols"][kind]

    market =
      Enum.find(candidates, &(&1.symbol == preferred and &1.active != false)) ||
        Enum.find(candidates, &(&1.active != false and String.starts_with?(&1.symbol || "", "BTC"))) ||
        Enum.find(candidates, &(&1.active != false))

    if market,
      do: market.symbol,
      else: flunk("#{context.venue}: no active #{kind} market can exercise the provider branch")
  end

  # Option instruments expire, so none is named in a contract file. The branch's
  # `option_instrument` says what the read needs the instrument to have now, and
  # the instrument is chosen from the venue's own live data at run time.
  @listed_horizon_ms 3_600_000

  defp with_selected_option(%{"option_instrument" => requirement} = contract_case, context) do
    Map.put(contract_case, "selected_option", select_option!(requirement, contract_case, context))
  end

  defp with_selected_option(contract_case, _context), do: contract_case

  defp select_option!("listed", contract_case, context) do
    cutoff = listed_cutoff()
    market = listed_option!(contract_case, context, listed_options(context, cutoff), cutoff)
    %{symbol: market.symbol, requirement: "listed", source: "load_markets", evidence: "an active listed option"}
  end

  # The source answers one underlying per call, so venue-wide absence is only
  # established after every listed underlying answered with rows, all of them
  # identified and none qualifying. Anything less leaves market state unverified.
  defp select_option!(requirement, contract_case, context) do
    cutoff = listed_cutoff()
    eligible = listed_options(context, cutoff)
    listed_option!(contract_case, context, eligible, cutoff)
    selection = context.venue_contract["option_selection"]
    source = selection["source_method"]

    searched =
      context.markets
      |> Enum.filter(&active_option?/1)
      |> option_groups(eligible)
      |> Enum.reduce_while([], fn group, searched ->
        verdict =
          case selection_rows(source, group.seed.symbol, group.base, selection, contract_case, context) do
            {:ok, rows} -> option_group_verdict(rows, group.listed, group.eligible, requirement)
            {:error, reason} -> {:source_error, reason}
          end

        case verdict do
          {:selected, row} -> {:halt, {:selected, row}}
          other -> {:cont, [{group.base, other} | searched]}
        end
      end)

    case searched do
      {:selected, row} ->
        %{symbol: row.symbol, requirement: requirement, source: source, evidence: option_evidence(row)}

      searched ->
        flunk(
          option_absence_message(contract_case["id"], context.venue, requirement, source, Enum.reverse(searched), cutoff)
        )
    end
  end

  @doc """
  Judges one underlying's selection-source rows for an option requirement.

  Every row is classified against that underlying's own listings, using the
  three-valued `requirement_check/2`:

    * candidate — `:yes` and names an eligible listing (active, not expiring
      within the hour)
    * unresolved, unknown identity — `:yes` but names no listing of the
      underlying, or is not a `Bourse.OptionData` row
    * unresolved, missing measurement — `:unknown`, identified or not
    * irrelevant — `:no`, whatever its identity, and any row naming a listing
      that only the expiry cutoff excludes

  Verdicts:

    * `{:selected, row}` — the candidate with the highest 24-hour volume,
      regardless of any other row
    * `{:unresolved, reasons}` — no candidate; `reasons` counts unresolved rows
      by `:identity` or `{:missing, fields}`
    * `:no_rows` — the source answered successfully with nothing
    * `{:absent, count}` — `count` rows, every one irrelevant
  """
  @spec option_group_verdict([term()], MapSet.t(), MapSet.t(), String.t()) ::
          {:selected, struct()} | {:unresolved, map()} | :no_rows | {:absent, pos_integer()}
  def option_group_verdict([], _listed, _eligible, _requirement), do: :no_rows

  def option_group_verdict(rows, listed, eligible, requirement) do
    classified = Enum.map(rows, &{classify_option_row(&1, listed, eligible, requirement), &1})
    candidates = for {:candidate, row} <- classified, do: row
    unresolved = for {{:unresolved, reason}, _row} <- classified, do: reason

    cond do
      candidates != [] -> {:selected, Enum.min_by(candidates, &{-option_volume(&1), &1.symbol})}
      unresolved != [] -> {:unresolved, Enum.frequencies(unresolved)}
      true -> {:absent, length(rows)}
    end
  end

  @doc """
  Decides whether one source row meets an option requirement.

  A missing measurement is never read as a negative one. A measurement is
  present when it is a number.

    * `quoted` reads `bid_price` and `ask_price`. Either one present and at or
      below zero answers `:no`, even when the other is missing. Both present and
      above zero answers `:yes`. Anything else answers `{:unknown, missing}`.
    * `traded` reads `base_volume` and `quote_volume`, which are alternatives.
      Either one present and above zero answers `:yes`. Both present and at or
      below zero answers `:no`. Anything else answers `{:unknown, missing}`,
      including a zero on one field when the other is missing.
  """
  @spec requirement_check(struct(), String.t()) :: :yes | :no | {:unknown, [atom()]}
  def requirement_check(row, "quoted") do
    values = [bid_price: row.bid_price, ask_price: row.ask_price]

    cond do
      Enum.any?(values, fn {_field, value} -> is_number(value) and value <= 0 end) -> :no
      Enum.all?(values, fn {_field, value} -> is_number(value) end) -> :yes
      true -> {:unknown, missing_fields(values)}
    end
  end

  def requirement_check(row, "traded") do
    values = [base_volume: row.base_volume, quote_volume: row.quote_volume]

    cond do
      Enum.any?(values, fn {_field, value} -> positive?(value) end) -> :yes
      Enum.all?(values, fn {_field, value} -> is_number(value) end) -> :no
      true -> {:unknown, missing_fields(values)}
    end
  end

  defp missing_fields(values), do: for({field, value} <- values, not is_number(value), do: field)

  defp classify_option_row(%Bourse.OptionData{} = row, listed, eligible, requirement) do
    identified? = MapSet.member?(listed, row.symbol)
    eligible? = MapSet.member?(eligible, row.symbol)

    case {identified? and not eligible?, requirement_check(row, requirement)} do
      {true, _check} -> :irrelevant
      {false, :no} -> :irrelevant
      {false, {:unknown, fields}} -> {:unresolved, {:missing, fields}}
      {false, :yes} when eligible? -> :candidate
      {false, :yes} -> {:unresolved, :identity}
    end
  end

  defp classify_option_row(_row, _listed, _eligible, _requirement), do: {:unresolved, :identity}

  @doc """
  Renders the failure for a selection that found no candidate.

  It states market-state absence only when every searched underlying answered
  `{:absent, _}`. Otherwise absence is not established.
  """
  @spec option_absence_message(String.t(), String.t(), String.t(), String.t(), [{String.t(), term()}], integer()) ::
          String.t()
  def option_absence_message(case_id, venue, requirement, source, searched, cutoff) do
    summary = Enum.map_join(searched, "; ", fn {base, verdict} -> "#{base}: #{group_detail(verdict, requirement)}" end)
    scope = "underlyings searched via #{source} (options expiring before #{iso8601(cutoff)} excluded): #{summary}"

    if Enum.all?(searched, &match?({_base, {:absent, _}}, &1)) do
      "#{case_id}: no eligible #{requirement} option instrument on #{venue} now — none has " <>
        "#{requirement_meaning(requirement)}. #{scope}. This is the venue's current market state, not a " <>
        "broken read: the branch was not called. Re-run when the venue's options are #{requirement} again."
    else
      "#{case_id}: absence of a #{requirement} option instrument on #{venue} not " <>
        "established — no identified candidate was found, and not every underlying answered with identified " <>
        "rows. #{scope}. Market state unverified: the branch was not called."
    end
  end

  defp group_detail({:absent, count}, requirement), do: "#{count} rows, none #{requirement}"

  defp group_detail({:unresolved, reasons}, requirement) do
    reasons
    |> Enum.sort()
    |> Enum.map_join(", ", fn
      {:identity, count} -> "#{count} #{requirement} rows of unknown identity"
      {{:missing, fields}, count} -> "#{count} rows with missing #{Enum.join(fields, " and ")} measurement"
    end)
  end

  defp group_detail(:no_rows, _requirement), do: "source returned no rows; market state unverified"
  defp group_detail({:source_error, reason}, _requirement), do: "source error #{reason}"

  defp option_groups(listed, eligible) do
    listed_by_base = Enum.group_by(listed, & &1.base)

    eligible
    |> Enum.group_by(& &1.base)
    |> Enum.map(fn {base, [seed | _] = markets} ->
      %{
        base: base,
        seed: seed,
        listed: MapSet.new(Map.get(listed_by_base, base, []), & &1.symbol),
        eligible: MapSet.new(markets, & &1.symbol)
      }
    end)
    |> Enum.sort_by(&{&1.base != "BTC", &1.base})
  end

  defp listed_option!(contract_case, context, eligible, cutoff) do
    case eligible do
      [market | _] ->
        market

      [] ->
        flunk(
          "#{contract_case["id"]}: no listed option instrument on #{context.venue} now — load_markets " <>
            "returned no active option expiring after #{iso8601(cutoff)}, so the branch was not called"
        )
    end
  end

  defp listed_cutoff, do: System.system_time(:millisecond) + @listed_horizon_ms

  defp listed_options(context, cutoff) do
    context.markets
    |> Enum.filter(&(active_option?(&1) and outlives?(&1, cutoff)))
    |> Enum.sort_by(&(not String.starts_with?(&1.symbol || "", "BTC")))
  end

  defp active_option?(market), do: market_kind?(market, "option") and market.active != false

  defp iso8601(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp outlives?(%{expiry: expiry}, horizon) when is_integer(expiry), do: expiry > horizon
  defp outlives?(_market, _horizon), do: true

  defp selection_rows(source, seed, base, selection, contract_case, context) do
    method = existing_method_atom!(source)
    selection_case = Map.put(contract_case, "selection_base", base)

    options =
      Enum.map(selection["options"], fn option ->
        {option_atom!(option["name"], contract_case), option_value!(option, selection_case, context)}
      end)

    case apply(Bourse, method, [context.exchange, seed, options]) do
      {:ok, rows} when is_map(rows) and not is_struct(rows) -> {:ok, Map.values(rows)}
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, "returned #{inspect(other, limit: 5)}"}
    end
  end

  defp positive?(value), do: is_number(value) and value > 0

  defp option_volume(row) do
    Enum.find([row.base_volume, row.quote_volume], 0, &positive?/1)
  end

  defp option_evidence(row) do
    "24h base volume #{inspect(row.base_volume)}, quote volume #{inspect(row.quote_volume)}, " <>
      "bid #{inspect(row.bid_price)}, ask #{inspect(row.ask_price)}"
  end

  defp requirement_meaning("quoted"), do: "a two-sided book (bid and ask above zero)"
  defp requirement_meaning("traded"), do: "24-hour trading volume above zero"

  defp market_kind?(market, "spot"), do: market.spot == true or market.type == "spot"
  defp market_kind?(market, "option"), do: market.option == true or market.type in ["option", "option_combo"]
  defp market_kind?(market, "inverse"), do: market.inverse == true and (market.swap == true or market.future == true)
  defp market_kind?(market, "linear"), do: market.linear == true and (market.swap == true or market.future == true)

  # An algo-book id is read from a book the previous case may have just emptied:
  # the source read can return an id whose `on_exit` cancel has not propagated,
  # and the branch then answers `order_not_found`. The case owns the order it
  # reads instead, so the route is proven against state it created.
  defp resource_value!(%{"source_kind" => "algo"} = argument, contract_case, context) do
    own_or_ledger_resource!(argument, contract_case, context, argument["collection"] == true)
  end

  defp resource_value!(%{"source_kind" => "transfer"} = argument, contract_case, context) do
    own_or_ledger_resource!(argument, contract_case, context, argument["collection"] == true)
  end

  defp resource_value!(argument, contract_case, context) do
    source = existing_method_atom!(argument["source_method"])

    source_result =
      apply(Bourse, source, [context.exchange, resource_source_options(argument, contract_case, context)])

    rows = successful_rows!(source_result, contract_case, argument["source_method"])
    collection? = argument["collection"] == true

    value = Enum.find_value(rows, &field_value(&1, argument["field"]))

    case value do
      nil ->
        own_or_ledger_resource!(argument, contract_case, context, collection?)

      value when collection? ->
        [value]

      value ->
        value
    end
  end

  defp own_or_ledger_resource!(argument, contract_case, context, collection?) do
    owned = Map.put(contract_case, "resolved_symbol", market_symbol!(context, contract_case))

    case RestReadContractOwnedState.ensure(argument, owned, context) do
      {:ok, value} when collection? ->
        [value]

      {:ok, value} ->
        value

      :unownable ->
        ledger_empty_resource!(argument, contract_case)

      {:error, reason} ->
        flunk(
          "#{contract_case["id"]}: failed to create sandbox state for #{argument["source_method"]}: #{format_reason(reason)}"
        )
    end
  end

  defp ledger_empty_collection!(contract_case) do
    case Ledger.classify(contract_case, :empty_collection) do
      {:ledgered, entry} ->
        Ledger.confirm!(entry, contract_case)

      :genuine ->
        flunk(unexercised_message(contract_case))
    end
  end

  defp ledger_empty_resource!(argument, contract_case) do
    case Ledger.classify(contract_case, {:empty_resource, argument["source_method"]}) do
      {:ledgered, entry} ->
        Ledger.confirm!(entry, contract_case)

      :genuine ->
        flunk(
          "#{contract_case["id"]}: provider account state has no #{argument["field"]} from #{argument["source_method"]}"
        )
    end
  end

  defp resource_source_options(argument, contract_case, context) do
    base =
      Enum.flat_map(contract_case["options"] || [], fn option ->
        case resource_option_atom(option["name"]) do
          nil -> []
          atom -> [{atom, option_value!(option, contract_case, context)}]
        end
      end)

    case argument["source_endpoint_index"] do
      nil ->
        base

      index when is_integer(index) and index >= 0 ->
        [{:endpoint_index, index} | base]

      other ->
        flunk("#{contract_case["id"]}: source_endpoint_index must be a non-negative integer, got #{inspect(other)}")
    end
  end

  defp resource_option_atom("account_index"), do: :account_index
  defp resource_option_atom("auth_deadline"), do: :auth_deadline
  defp resource_option_atom("subaccount_id"), do: :subaccount_id
  defp resource_option_atom("symbol"), do: :symbol
  defp resource_option_atom("category"), do: :category
  defp resource_option_atom("currency"), do: :currency
  defp resource_option_atom("instType"), do: :instType
  defp resource_option_atom(_name), do: nil

  defp successful_rows!({:ok, %RawResponse{payload: payload}}, contract_case, source),
    do: payload_rows!(payload, contract_case, source)

  defp successful_rows!({:ok, rows}, _contract_case, _source) when is_list(rows), do: rows

  # A parsed struct's provider payload rides on :info; account-level fields
  # (e.g. lighter's l1_address) live in those raw rows, not on the struct.
  defp successful_rows!({:ok, %_{info: info} = struct}, _contract_case, _source) when is_map(info) or is_list(info) do
    (struct |> Map.from_struct() |> Map.values()) ++ find_first_collection(info)
  end

  defp successful_rows!({:ok, rows}, _contract_case, _source) when is_map(rows), do: Map.values(rows)

  defp successful_rows!({:error, reason}, contract_case, source),
    do: flunk("#{contract_case["id"]}: resource source #{source} failed: #{format_reason(reason)}")

  defp successful_rows!(other, contract_case, source),
    do: flunk("#{contract_case["id"]}: resource source #{source} returned #{inspect(other)}")

  defp payload_rows!(payload, _contract_case, _source), do: find_first_collection(payload)

  defp find_first_collection(value) when is_list(value), do: value

  defp find_first_collection(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.find_value([], fn child ->
      rows = find_first_collection(child)
      if rows == [], do: nil, else: rows
    end)
  end

  defp find_first_collection(_value), do: []

  defp field_value(%_{} = struct, field), do: maybe_atom_field(struct, field)
  defp field_value(map, field) when is_map(map), do: Map.get(map, field) || maybe_atom_field(map, field)
  defp field_value(_value, _field), do: nil

  defp maybe_atom_field(map, field) do
    field_atom = field |> Macro.underscore() |> String.to_existing_atom()
    Map.get(map, field_atom)
  rescue
    ArgumentError -> nil
  end

  defp assert_success!(contract_case, {:ok, value}, resolved) do
    assert_representation!(contract_case, value)
    assert_meaning!(contract_case, value, resolved)
    :ok
  end

  defp assert_success!(contract_case, {:error, reason}, _resolved) do
    case Ledger.classify(contract_case, {:error, reason}) do
      {:ledgered, entry} ->
        Ledger.confirm!(entry, contract_case)

      :genuine ->
        flunk("#{contract_case["id"]}: live provider success failed: #{format_reason(reason)}")
    end
  end

  defp assert_success!(contract_case, other, _resolved),
    do: flunk("#{contract_case["id"]}: live provider returned #{inspect(other)}")

  defp assert_representation!(%{"success" => %{"representation" => "raw"}} = contract_case, value) do
    assert %RawResponse{venue: venue, method: method, payload: payload} = value
    assert venue == contract_case["venue"]
    assert method == contract_case["method"]
    refute is_nil(payload), "#{contract_case["id"]}: provider payload is nil"
  end

  defp assert_representation!(%{"success" => %{"representation" => "nested_map"}} = contract_case, value) do
    assert is_map(value) and not is_struct(value),
           "#{contract_case["id"]}: expected a provider map, got #{inspect(value)}"

    assert map_size(value) > 0, "#{contract_case["id"]}: provider returned an empty map"
  end

  defp assert_representation!(contract_case, %RawResponse{}),
    do:
      flunk(
        "#{contract_case["id"]}: expected provider-defined #{contract_case["success_contract"]}, got labelled raw data"
      )

  defp assert_representation!(%{"success" => %{"collection" => "scalar"} = success} = contract_case, value) do
    assert_scalar!(contract_case, value, success["scalar"])
  end

  defp assert_representation!(%{"success" => %{"representation" => "positional_rows"} = success} = contract_case, value) do
    assert is_list(value), "#{contract_case["id"]}: expected positional provider rows"

    if value == [] do
      ledger_empty_collection!(contract_case)
    end

    assert Enum.all?(value, &(is_list(&1) and length(&1) >= success["minimum_length"])),
           "#{contract_case["id"]}: provider returned an invalid positional row"
  end

  defp assert_representation!(contract_case, value) do
    success = contract_case["success"]
    module = module_from_data(success["module"])

    case success["collection"] do
      "single" ->
        if value in [nil, []] do
          ledger_empty_collection!(contract_case)
        else
          assert is_struct(value, module), "#{contract_case["id"]}: expected #{inspect(module)}, got #{inspect(value)}"
        end

      collection when collection in ["list", "map"] ->
        assert_collection!(contract_case, value, module, collection)
    end
  end

  defp assert_collection!(contract_case, value, module, "list") do
    assert is_list(value), "#{contract_case["id"]}: expected a provider list, got #{inspect(value)}"

    if empty_unexercised?(contract_case) and value == [] do
      ledger_empty_collection!(contract_case)
    end

    if value != [] do
      assert Enum.all?(value, &is_struct(&1, module)),
             "#{contract_case["id"]}: collection contains a non-#{inspect(module)} value"
    end
  end

  defp assert_collection!(contract_case, value, module, "map") do
    assert is_map(value), "#{contract_case["id"]}: expected a provider map, got #{inspect(value)}"

    if empty_unexercised?(contract_case) and map_size(value) == 0 do
      ledger_empty_collection!(contract_case)
    end

    if map_size(value) > 0 do
      assert Enum.all?(value, fn {_key, entry} -> is_struct(entry, module) end),
             "#{contract_case["id"]}: map contains a non-#{inspect(module)} value"
    end
  end

  defp empty_unexercised?(contract_case) do
    contract_case["success"]["empty_collection"] != "allowed"
  end

  defp unexercised_message(%{"selected_option" => %{source: "load_markets"} = selected} = contract_case) do
    "#{contract_case["id"]}: the read returned nothing for the listed option #{selected.symbol}. " <>
      "A listed instrument is all this branch needs, so an empty answer is a broken read, not market state."
  end

  defp unexercised_message(%{"selected_option" => selected} = contract_case) do
    "#{contract_case["id"]}: the read returned nothing for #{selected.symbol}, which #{selected.source} " <>
      "reported as #{selected.requirement} (#{selected.evidence}). The venue publishes what this branch " <>
      "reads, so the empty answer is a broken read, not market state."
  end

  defp unexercised_message(contract_case) do
    "#{contract_case["id"]}: provider account/market state did not exercise the read. " <>
      "Populate the sandbox account or market so this branch returns a non-empty result, " <>
      "then re-run `mix bourse.verify_rest_read_contracts`."
  end

  defp assert_scalar!(contract_case, value, "integer") do
    assert is_integer(value), "#{contract_case["id"]}: expected integer semantics, got #{inspect(value)}"

    Enum.each(List.wrap(contract_case["success"]["invariants"]), fn invariant ->
      assert_scalar_invariant!(contract_case, invariant, value)
    end)
  end

  defp assert_scalar_invariant!(contract_case, %{"operator" => "recent_ms", "tolerance_ms" => tolerance}, value)
       when is_integer(tolerance) do
    assert abs(System.system_time(:millisecond) - value) <= tolerance,
           "#{contract_case["id"]}: provider time is not current milliseconds"
  end

  defp assert_meaning!(
         %{"success" => %{"representation" => "raw"}} = contract_case,
         %RawResponse{payload: payload},
         _resolved
       ) do
    keys = contract_case["success"]["provider_meaning_keys"]
    assert_provider_meaning_keys!(contract_case, payload, keys)
  end

  defp assert_meaning!(%{"success" => %{"representation" => "nested_map"}} = contract_case, value, _resolved) do
    keys = contract_case["success"]["provider_meaning_keys"]
    assert_provider_meaning_keys!(contract_case, value, keys)
  end

  defp assert_meaning!(
         %{"success" => %{"representation" => "positional_rows"} = success} = contract_case,
         rows,
         _resolved
       ) do
    Enum.each(rows, &assert_positional_row!(contract_case, success, &1))
  end

  defp assert_meaning!(contract_case, value, resolved) do
    values = semantic_values(value, contract_case["success"]["collection"])
    success = contract_case["success"]

    Enum.each(values, fn semantic_value ->
      Enum.each(success["required_fields"], fn field ->
        refute is_nil(field_value(semantic_value, field)),
               "#{contract_case["id"]}: required semantic field #{field} is nil"
      end)

      if success["any_fields"] != [] do
        assert Enum.any?(success["any_fields"], &(not is_nil(field_value(semantic_value, &1)))),
               "#{contract_case["id"]}: none of #{inspect(success["any_fields"])} carries provider meaning"
      end

      Enum.each(List.wrap(success["nonempty_maps"]), fn field ->
        map = field_value(semantic_value, field)

        assert is_map(map) and map_size(map) > 0,
               "#{contract_case["id"]}: #{field} must be a non-empty map, got #{inspect(map)}"
      end)

      assert_field_values!(contract_case, semantic_value, Map.get(success, "field_values", %{}))
    end)

    assert_symbol_meaning!(contract_case, values, resolved)
  end

  defp assert_field_values!(contract_case, semantic_value, field_values) when is_map(field_values) do
    Enum.each(field_values, fn {field, allowed} ->
      value = field_value(semantic_value, field)

      assert value in allowed,
             "#{contract_case["id"]}: #{field} is #{inspect(value)}, expected one of #{inspect(allowed)}"
    end)
  end

  defp assert_provider_meaning_keys!(contract_case, value, keys) do
    cond do
      contains_meaning?(value, keys) ->
        :ok

      all_collections_empty?(value) and contract_case["success"]["empty_collection"] == "allowed" ->
        :ok

      all_collections_empty?(value) ->
        case Ledger.classify(contract_case, :empty_payload) do
          {:ledgered, entry} ->
            Ledger.confirm!(entry, contract_case)

          :genuine ->
            flunk(
              "#{contract_case["id"]}: provider returned no rows (empty collection). " <>
                "This is empty account state, not a missing-key carve. Populate the sandbox " <>
                "account so this read has data, or ledger the branch in docs/prod-verification-ledger.md"
            )
        end

      true ->
        flunk(
          "#{contract_case["id"]}: rows are present but none of them carry the semantic keys #{inspect(keys)}. " <>
            "This is a shape/carve mismatch, not empty account state."
        )
    end
  end

  defp semantic_values(value, "single"), do: [value]
  defp semantic_values(value, "list") when is_list(value), do: value
  defp semantic_values(value, "map") when is_map(value), do: Map.values(value)
  defp semantic_values(_value, "scalar"), do: []

  defp assert_symbol_meaning!(contract_case, values, %{"symbol" => symbol}) do
    symbol_values = values |> Enum.map(&field_value(&1, "symbol")) |> Enum.reject(&is_nil/1)

    if symbol_values != [] do
      assert symbol in symbol_values,
             "#{contract_case["id"]}: provider result symbols #{inspect(symbol_values)} omit requested #{symbol}"
    end
  end

  defp assert_symbol_meaning!(_contract_case, _values, _resolved), do: :ok

  defp assert_positional_row!(contract_case, success, row) do
    values =
      Map.new(success["fields"], fn field ->
        value = Enum.at(row, field["index"])
        assert_field_type!(contract_case, field, value)
        {field["name"], value}
      end)

    Enum.each(success["invariants"], &assert_invariant!(contract_case, &1, values))
  end

  defp assert_field_type!(contract_case, %{"name" => name, "type" => "integer"}, value) do
    assert is_integer(value), "#{contract_case["id"]}: #{name} is not an integer"
  end

  defp assert_field_type!(contract_case, %{"name" => name, "type" => "number"}, value) do
    assert is_number(value), "#{contract_case["id"]}: #{name} is not numeric"
  end

  defp assert_invariant!(contract_case, %{"operator" => "gte"} = invariant, values) do
    assert values[invariant["left"]] >= values[invariant["right"]],
           "#{contract_case["id"]}: #{invariant["left"]} is below #{invariant["right"]}"
  end

  defp assert_invariant!(contract_case, %{"operator" => "between"} = invariant, values) do
    value = values[invariant["value"]]

    assert value >= values[invariant["minimum"]] and value <= values[invariant["maximum"]],
           "#{contract_case["id"]}: #{invariant["value"]} is outside provider bounds"
  end

  defp contains_meaning?(value, keys) when is_map(value) do
    Enum.any?(value, fn {key, child} ->
      (key_match?(to_string(key), keys) and meaningful?(child)) or contains_meaning?(child, keys)
    end)
  end

  defp contains_meaning?(value, keys) when is_list(value), do: Enum.any?(value, &contains_meaning?(&1, keys))
  defp contains_meaning?(_value, _keys), do: false

  # A venue that answers 200 with an empty collection is reporting "no rows", not a
  # shape mismatch. Without this split both conditions raise "contains none of the
  # semantic keys", which reads as carve divergence and sends the reader hunting for
  # a parse defect that is not there (BUGS.md, bybit fetchMySettlementHistory).
  defp all_collections_empty?(value) do
    case collect_lists(value, []) do
      [] -> false
      lists -> Enum.all?(lists, &(&1 == []))
    end
  end

  defp collect_lists(value, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {_key, child}, inner -> collect_lists(child, inner) end)
  end

  defp collect_lists(value, acc) when is_list(value) do
    Enum.reduce(value, [value | acc], fn child, inner -> collect_lists(child, inner) end)
  end

  defp collect_lists(_value, acc), do: acc

  defp key_match?(key, keys) do
    normalized = String.downcase(key)
    Enum.any?(keys, &String.contains?(normalized, String.downcase(&1)))
  end

  defp meaningful?(nil), do: false
  defp meaningful?(""), do: false
  defp meaningful?([]), do: false
  defp meaningful?(map) when is_map(map), do: map_size(map) > 0
  defp meaningful?(_value), do: true

  defp module_from_data(module_name) when is_binary(module_name) do
    module_name
    |> String.split(".")
    |> Module.concat()
  end

  defp existing_method_atom!(js_name) do
    Unified.method_atom_for_js_name(js_name) || flunk("unknown unified REST-read method #{inspect(js_name)}")
  end

  defp format_reason(%Error{} = reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)
end
