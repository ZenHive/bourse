defmodule Bourse.Unified.FieldMaps do
  @moduledoc """
  Derives unified struct field sets from authored `normalization.field_maps`.

  The source of truth is the union of canonical unified keys authored per parse
  type across the supported venues. The
  hand-authored structs (`Bourse.Ticker`, `Bourse.Order`, ...) keep their curated
  docs, typespecs, and helper functions, but their *field set* is governed by
  the spec — `Bourse.Unified.FieldMapsTest` fails the build when a struct drifts
  from the derived canonical set.

  ## Why governance, not full code generation

  Most `field_maps` belong to the core `parse*` types; many derivative structs
  have no authored field map to derive
  from). A few Tier 2/3 types do carry one and are governed alongside the core
  set (e.g. `Bourse.OpenInterest`), so `@struct_for` is the authoritative governed
  list rather than a fixed count. And the core structs carry curated helpers
  (`Bourse.Order` status predicates,
  `Bourse.Balance.get/2`, `Bourse.OHLCV.from_list/1`) that no generator can emit.
  So the spec governs the *field set* (drift-guarded by a test), not the full
  module source.

  ## Honesty Rule

  A canonical key appears in the derived set even when no exchange statically
  resolved a coercion for it (`field_map[key] == null`) — it is part of Bourse's
  unified shape and surfaces as a `nil`-valued struct field. Slots carrying a
  non-nil `_unresolved_reason` (e.g. `multi_payload_branching:<N>`) still
  contribute whatever keys they expose.

  ## Naming divergences

  A small set of canonical keys map to a different struct field name by design
  (mirrored in `Bourse.ResponseParser`). These are listed in `divergences/1` and
  applied when computing the canonical field set for a struct.

  Field names are surfaced as snake_case strings (not atoms): the derived set is
  compared against struct keys at governance time, so deriving atoms from raw
  spec strings would grow the atom table for no consumer benefit.

      iex> "ask" in Bourse.Unified.FieldMaps.canonical_fields("ticker")
      true

      iex> Bourse.Unified.FieldMaps.coercion_type("safeNumber")
      :number
  """

  alias Bourse.Spec

  # Parse type (field_maps slot) -> unified struct module governed by it.
  @struct_for %{
    "account" => Bourse.Account,
    "balance" => Bourse.Balance,
    "borrow_interest" => Bourse.BorrowInterest,
    "borrow_rate" => Bourse.BorrowRate,
    "conversion" => Bourse.Conversion,
    "currency" => Bourse.Currency,
    "deposit_address" => Bourse.DepositAddress,
    "funding_rate" => Bourse.FundingRate,
    "funding_rate_history" => Bourse.FundingRateHistory,
    "funding_history" => Bourse.FundingHistory,
    "greeks" => Bourse.Greeks,
    "last_price" => Bourse.LastPrice,
    "ledger_entry" => Bourse.LedgerEntry,
    "leverage" => Bourse.Leverage,
    "leverage_tiers" => Bourse.LeverageTier,
    "liquidation" => Bourse.Liquidation,
    "long_short_ratio" => Bourse.LongShortRatio,
    "margin_loan" => Bourse.MarginLoan,
    "margin_mode" => Bourse.MarginMode,
    "margin_modification" => Bourse.MarginModification,
    "market" => Bourse.Market,
    "ohlcv" => Bourse.OHLCV,
    "open_interest" => Bourse.OpenInterest,
    "option" => Bourse.OptionData,
    "order" => Bourse.Order,
    "order_list" => Bourse.OrderList,
    "position" => Bourse.Position,
    "adl_rank" => Bourse.ADLRank,
    "ticker" => Bourse.Ticker,
    "trade" => Bourse.Trade,
    "trading_fee" => Bourse.TradingFee,
    "transaction" => Bourse.Transaction,
    "transfer" => Bourse.TransferEntry,
    "volatility_history" => Bourse.VolatilityHistory
  }

  # Canonical-key -> struct-field renames, per parse type. Mirrors
  # Bourse.ResponseParser.normalize_output_key/2 (e.g. trade `order` -> `order_id`,
  # which avoids colliding with the order *struct*). snake_case strings.
  @divergences %{
    "trade" => %{"order" => "order_id"}
  }

  # Coercion vocabulary -> JSONSpec scalar type. Mirrors the runtime coercion in
  # Bourse.ResponseParser.coerce/2. A `nil` coercion (unresolved canonical key)
  # maps to :unknown — the field still exists, its type is just not derivable.
  @coercion_types %{
    "safeString" => :string,
    "safeString2" => :string,
    "safeStringLower" => :string,
    "safeInteger" => :integer,
    "safeInteger2" => :integer,
    "safeNumber" => :number,
    "safeNumber2" => :number,
    "safeBool" => :boolean
  }

  @doc """
  Returns the parse types (field_maps slots) that govern a unified struct.
  """
  @spec parse_types() :: [String.t()]
  def parse_types, do: @struct_for |> Map.keys() |> Enum.sort()

  @doc """
  Returns the unified struct module governed by a parse type, or `nil`.
  """
  @spec struct_for(String.t()) :: module() | nil
  def struct_for(parse_type) when is_binary(parse_type), do: Map.get(@struct_for, parse_type)

  @doc """
  Returns the by-design canonical-key -> struct-field renames for a parse type.
  """
  @spec divergences(String.t()) :: %{String.t() => String.t()}
  def divergences(parse_type) when is_binary(parse_type), do: Map.get(@divergences, parse_type, %{})

  # Reverse index: unified struct module -> its governing parse type.
  @struct_to_type Map.new(@struct_for, fn {parse_type, module} -> {module, parse_type} end)

  @doc """
  Returns the by-design canonical-key -> struct-field renames for a unified struct
  module, or an empty map. Lets a verifier reconcile our struct field names
  (`order_id`) against Bourse's canonical keys (`order`) from the same source of
  truth as the runtime parser.
  """
  @spec divergences_for_struct(module() | nil) :: %{String.t() => String.t()}
  def divergences_for_struct(module) when is_atom(module) do
    case Map.get(@struct_to_type, module) do
      nil -> %{}
      parse_type -> divergences(parse_type)
    end
  end

  @doc """
  Maps a coercion vocabulary token to its JSONSpec scalar type.

  Returns `:unknown` for a `nil` coercion (an unresolved canonical key) or an
  unrecognised token.
  """
  @spec coercion_type(String.t() | nil) :: :string | :integer | :number | :boolean | :unknown
  def coercion_type(coercion) when is_binary(coercion), do: Map.get(@coercion_types, coercion, :unknown)
  def coercion_type(_coercion), do: :unknown

  @doc """
  Derives the canonical field set for a parse type as a sorted list of
  snake_case strings.

  The set is the union of `field_map` keys across all in-scope exchange specs,
  converted to snake_case, with the parse type's `divergences/1` renames
  applied. OHLCV carries no field map (array shape) and yields `[]`.

      iex> fields = Bourse.Unified.FieldMaps.canonical_fields("trade")
      iex> "order_id" in fields and "order" not in fields
      true
  """
  @spec canonical_fields(String.t()) :: [String.t()]
  def canonical_fields(parse_type) when is_binary(parse_type) do
    renames = divergences(parse_type)

    parse_type
    |> raw_keys()
    |> Enum.map(&Macro.underscore/1)
    |> Enum.map(&Map.get(renames, &1, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Derives the full canonical field set per parse type as `%{parse_type => [str]}`.
  """
  @spec canonical_field_sets() :: %{String.t() => [String.t()]}
  def canonical_field_sets do
    Map.new(parse_types(), fn parse_type -> {parse_type, canonical_fields(parse_type)} end)
  end

  # Union of raw (camelCase) field_map keys for a parse type across all specs.
  @spec raw_keys(String.t()) :: [String.t()]
  defp raw_keys(parse_type) do
    Spec.exchanges()
    |> Enum.flat_map(&slot_keys(&1, parse_type))
    |> Enum.uniq()
  end

  defp slot_keys(exchange_id, parse_type) do
    case Spec.load!(exchange_id) do
      %{"normalization" => %{"field_maps" => %{^parse_type => %{"field_map" => field_map}}}}
      when is_map(field_map) ->
        Map.keys(field_map)

      _ ->
        []
    end
  end
end
