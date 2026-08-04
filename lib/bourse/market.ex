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
    * `type` - Market type: "spot", "swap", "future", "option"
    * `sub_type` - "linear" or "inverse" for derivatives
    * `spot`, `margin`, `swap`, `future`, `option`, `contract` - Type flags
    * `active` - Whether the market is currently trading
    * `settle`, `settle_id` - Settlement currency
    * `contract_size` - Contract size for derivatives
    * `quantity_unit` - Canonical option quantity unit (`"base"`)
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
                   type: "Market type: spot, swap, future, option",
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
                   contract_size: "Contract size for derivatives",
                   quantity_unit: "Canonical option quantity unit (base currency)",
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
end
