defmodule Bourse.Market do
  @moduledoc """
  Unified market/instrument metadata.

  Describes a trading pair and its properties — spot, derivatives,
  precision, limits, and fee structure.

  ## Fields

    * `id` - Exchange-native market ID (e.g., "BTCUSDT")
    * `symbol` - Unified symbol (e.g., "BTC/USDT")
    * `base`, `quote` - Base and quote currency codes
    * `base_id`, `quote_id` - Exchange-native currency IDs
    * `type` - Market type: "spot", "swap", "future", "option". Multi-leg
      books that do not satisfy a single-leg type keep the venue kind
      (`"option_combo"`, `"future_combo"`) instead of borrowing `option` /
      `future`.
    * `sub_type` - "linear" or "inverse" for derivatives
    * `spot`, `margin`, `swap`, `future`, `option`, `contract` - Type flags
    * `active` - Whether the market is currently trading
    * `settle`, `settle_id` - Settlement currency
    * `contract_size` - Base-asset units represented by one contract. Linear
      quantity is already base-denominated, so this is the venue's contract
      unit (1 for Binance USD-M BTCUSDT). Inverse venues publish a multiplier
      (100 USD for Binance COIN-M BTCUSD). Linear notional is
      `quantity * price * contract_size`; inverse notional is
      `contracts * contract_size`. Nil when the venue states no unit. On a
      multi-leg book (`combo?/1`) the mark is a spread or premium
      difference, not an underlying — do not form a notional against it.
    * `quantity_unit` - Denomination of order quantity. `"base"` for
      base-asset linear contracts and for the canonical option unit.
    * `native_quantity_unit` - Venue option quantity unit (`"base"` or `"contracts"`)
    * `native_quantity_field` - Venue option order field carrying the quantity
    * `native_amount_step` - Venue-native quantity increment before conversion
    * `linear`, `inverse` - Settlement direction flags
    * `expiry`, `expiry_datetime` - Futures/options expiration
    * `strike` - Options strike price
    * `option_type` - "call" or "put"
    * `taker`, `maker` - Fee rates as decimals
    * `percentage` - Whether fees are charged as a percentage
    * `tier_based` - Whether fees use a tiered schedule
    * `precision_mode` - Authored precision interpretation mode
    * `precision` - Price/amount/cost precision rules
    * `limits` - Min/max for price, amount, cost, leverage
    * `created` - Market listing timestamp in milliseconds
    * `asset_index` - Venue signing index for L1 actions (Hyperliquid: meta/spotMeta
      universe position with spot/HIP-3 offsets). Explicit — not overloaded onto
      `id`/`base_id` (carve C-T339).
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          symbol: String.t() | nil,
          base: String.t() | nil,
          quote: String.t() | nil,
          base_id: String.t() | nil,
          quote_id: String.t() | nil,
          type: String.t() | nil,
          sub_type: String.t() | nil,
          spot: boolean() | nil,
          margin: boolean() | nil,
          swap: boolean() | nil,
          future: boolean() | nil,
          option: boolean() | nil,
          contract: boolean() | nil,
          active: boolean() | nil,
          settle: String.t() | nil,
          settle_id: String.t() | nil,
          contract_size: number() | nil,
          quantity_unit: String.t() | nil,
          native_quantity_unit: String.t() | nil,
          native_quantity_field: String.t() | nil,
          native_amount_step: number() | nil,
          linear: boolean() | nil,
          inverse: boolean() | nil,
          expiry: integer() | nil,
          expiry_datetime: String.t() | nil,
          strike: number() | nil,
          option_type: String.t() | nil,
          taker: number() | nil,
          maker: number() | nil,
          percentage: boolean() | nil,
          tier_based: boolean() | nil,
          precision_mode: String.t() | nil,
          precision: map() | nil,
          limits: map() | nil,
          created: integer() | nil,
          asset_index: integer() | nil,
          info: map() | nil
        }

  defstruct [
    :id,
    :symbol,
    :base,
    :quote,
    :base_id,
    :quote_id,
    :type,
    :sub_type,
    :spot,
    :margin,
    :swap,
    :future,
    :option,
    :contract,
    :active,
    :settle,
    :settle_id,
    :contract_size,
    :quantity_unit,
    :native_quantity_unit,
    :native_quantity_field,
    :native_amount_step,
    :linear,
    :inverse,
    :expiry,
    :expiry_datetime,
    :strike,
    :option_type,
    :taker,
    :maker,
    :percentage,
    :tier_based,
    :precision_mode,
    :precision,
    :limits,
    :created,
    :asset_index,
    :info
  ]

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   symbol: String.t() | nil,
                   base: String.t() | nil,
                   quote: String.t() | nil,
                   base_id: String.t() | nil,
                   quote_id: String.t() | nil,
                   type: String.t() | nil,
                   sub_type: String.t() | nil,
                   spot: boolean() | nil,
                   margin: boolean() | nil,
                   swap: boolean() | nil,
                   future: boolean() | nil,
                   option: boolean() | nil,
                   contract: boolean() | nil,
                   active: boolean() | nil,
                   settle: String.t() | nil,
                   settle_id: String.t() | nil,
                   contract_size: number() | nil,
                   quantity_unit: String.t() | nil,
                   native_quantity_unit: String.t() | nil,
                   native_quantity_field: String.t() | nil,
                   native_amount_step: number() | nil,
                   linear: boolean() | nil,
                   inverse: boolean() | nil,
                   expiry: integer() | nil,
                   expiry_datetime: String.t() | nil,
                   strike: number() | nil,
                   option_type: String.t() | nil,
                   taker: number() | nil,
                   maker: number() | nil,
                   percentage: boolean() | nil,
                   tier_based: boolean() | nil,
                   precision_mode: String.t() | nil,
                   precision: map() | nil,
                   limits: map() | nil,
                   created: integer() | nil,
                   asset_index: integer() | nil,
                   info: map() | nil
                 },
                 doc: [
                   id: "Exchange-native market ID (e.g., BTCUSDT)",
                   symbol: "Unified symbol (e.g., BTC/USDT)",
                   base: "Base currency code",
                   quote: "Quote currency code",
                   base_id: "Exchange-native base currency ID",
                   quote_id: "Exchange-native quote currency ID",
                   type:
                     "Market type: spot, swap, future, option. Multi-leg books that do not satisfy a single-leg type keep the venue kind (option_combo, future_combo).",
                   sub_type: "linear or inverse for derivatives",
                   spot: "Whether this is a spot market",
                   margin: "Whether margin trading is available",
                   swap: "Whether this is a perpetual swap",
                   future: "Whether this is a futures contract",
                   option: "Whether this is an options contract",
                   contract: "Whether this is a contract market",
                   active: "Whether the market is currently trading",
                   settle: "Settlement currency code",
                   settle_id: "Exchange-native settlement currency ID",
                   contract_size:
                     "Base-asset units per contract. Linear notional is quantity * price * contract_size; inverse notional is contracts * contract_size. Nil when the venue states no unit. Combo mark is a spread/premium difference — not an underlying — so notional-style arithmetic against it is invalid.",
                   quantity_unit: "Order quantity denomination: base for linear contracts and canonical option quantity",
                   native_quantity_unit: "Venue option quantity unit: base or contracts",
                   native_quantity_field: "Venue order field carrying the option quantity",
                   native_amount_step: "Venue-native option quantity increment",
                   linear: "Whether settlement is in quote currency",
                   inverse: "Whether settlement is in base currency",
                   expiry: "Futures/options expiration timestamp in milliseconds",
                   expiry_datetime: "Expiration as ISO 8601 datetime",
                   strike: "Options strike price",
                   option_type: "call or put",
                   taker: "Taker fee rate as decimal",
                   maker: "Maker fee rate as decimal",
                   percentage: "Whether fees are charged as a percentage",
                   tier_based: "Whether fees use a tiered schedule",
                   precision_mode: "Authored precision interpretation mode",
                   precision: "Price/amount/cost precision rules",
                   limits: "Min/max for price, amount, cost, leverage",
                   created: "Market listing timestamp in milliseconds",
                   asset_index: "Venue L1 signing index (Hyperliquid universe position + offsets)",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Market unified type."
  @spec schema() :: map()
  def schema, do: @json_schema

  @doc """
  True when this market is a multi-leg combo/strategy book.

  Deribit `option_combo` / `future_combo` are the current cases. The mark
  of a combo is a spread or premium difference between legs, not an
  underlying price — `contracts * contract_size / mark` is not a notional.
  """
  @spec combo?(t()) :: boolean()
  def combo?(%__MODULE__{type: type}) when type in ["option_combo", "future_combo"], do: true

  def combo?(%__MODULE__{info: %{"kind" => kind}}) when kind in ["option_combo", "future_combo"], do: true

  def combo?(_market), do: false

  @doc """
  True when `contract_size` has a resolvable unit for exposure math.

  False when this is a multi-leg combo, and false when both
  `native_quantity_unit` and `quantity_unit` are unset on a market that is
  not a single-leg inverse or linear contract with a published size.
  Block exposure on `false` rather than multiplying by a unit-less
  `contract_size`.
  """
  @spec quantity_resolvable?(t()) :: boolean()
  def quantity_resolvable?(%__MODULE__{} = market) do
    cond do
      combo?(market) -> false
      is_binary(market.native_quantity_unit) and market.native_quantity_unit != "" -> true
      is_binary(market.quantity_unit) and market.quantity_unit != "" -> true
      single_leg_contract_unit?(market) -> true
      true -> false
    end
  end

  defp single_leg_contract_unit?(%__MODULE__{contract: true, contract_size: size} = market)
       when is_number(size) and size > 0 do
    market.inverse == true or market.linear == true
  end

  defp single_leg_contract_unit?(_market), do: false
end
