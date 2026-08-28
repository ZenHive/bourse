defmodule Bourse.Position do
  @moduledoc """
  Unified derivatives position data.

  Represents an open position on a derivatives exchange (futures, swaps, options).

  ## Fields

    * `id` - Position ID
    * `symbol` - Unified symbol (e.g., "BTC/USDT:USDT")
    * `timestamp` - Last update time in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `side` - "long" or "short"
    * `contracts` - Number of contracts
    * `contract_size` - Size of one contract
    * `notional` - Absolute position value denominated by `notional_currency`.
      On an option it is mark-to-market premium value, not strike or index
      exposure: OKX `optVal`, Bybit `positionValue`, and Deribit
      `contracts * contract_size * mark_price` are that cash value, and
      unlike exposures are not additive.
    * `notional_currency` - Unified currency code that denominates `notional`.
      Populated whenever `notional` is populated on the unified read path.
    * `base_quantity` - Absolute position size in the base currency. Populated
      only for Deribit future rows from `size_currency`. It is `nil` for Deribit
      options and other venues; their `contracts` may already be base-denominated.
    * `leverage` - Current leverage
    * `unrealized_pnl` - Unrealized profit/loss
    * `realized_pnl` - Realized profit/loss
    * `cumulative_funding` - Funding settled for the position
    * `pending_funding` - Funding not yet settled into cash balance
    * `total_fees` - Fees paid while opening or changing the position
    * `net_settlements` - Net USD paid or received from settlements
    * `collateral` - Collateral amount
    * `entry_price` - Average entry price
    * `mark_price` - Current mark price
    * `liquidation_price` - Estimated liquidation price
    * `margin_mode` - "cross" or "isolated"
    * `isolated` - Whether the position uses isolated margin
    * `hedged` - Whether position is in hedge mode
    * `maintenance_margin` - Required maintenance margin
    * `maintenance_margin_percentage` - Maintenance margin as a fraction (0.1 = 10%)
    * `initial_margin` - Required initial margin
    * `initial_margin_percentage` - Initial margin as a fraction (0.1 = 10%)
    * `margin_ratio` - Current margin ratio as a fraction (0.1 = 10%)
    * `last_update_timestamp` - Last update timestamp
    * `last_price` - Last traded price
    * `stop_loss_price` - Stop loss price
    * `take_profit_price` - Take profit price
    * `percentage` - PnL in percent points (10 = 10%)
    * `margin` - Position margin
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          side: String.t() | nil,
          contracts: number() | nil,
          contract_size: number() | nil,
          notional: number() | nil,
          notional_currency: String.t() | nil,
          base_quantity: number() | nil,
          leverage: number() | nil,
          unrealized_pnl: number() | nil,
          realized_pnl: number() | nil,
          cumulative_funding: number() | nil,
          pending_funding: number() | nil,
          total_fees: number() | nil,
          net_settlements: number() | nil,
          collateral: number() | nil,
          entry_price: number() | nil,
          mark_price: number() | nil,
          liquidation_price: number() | nil,
          margin_mode: String.t() | nil,
          isolated: boolean() | nil,
          hedged: boolean() | nil,
          maintenance_margin: number() | nil,
          maintenance_margin_percentage: number() | nil,
          initial_margin: number() | nil,
          initial_margin_percentage: number() | nil,
          margin_ratio: number() | nil,
          last_update_timestamp: integer() | nil,
          last_price: number() | nil,
          stop_loss_price: number() | nil,
          take_profit_price: number() | nil,
          percentage: number() | nil,
          margin: number() | nil,
          info: map() | nil
        }

  defstruct [
    :id,
    :symbol,
    :timestamp,
    :datetime,
    :side,
    :contracts,
    :contract_size,
    :notional,
    :notional_currency,
    :base_quantity,
    :leverage,
    :unrealized_pnl,
    :realized_pnl,
    :cumulative_funding,
    :pending_funding,
    :total_fees,
    :net_settlements,
    :collateral,
    :entry_price,
    :mark_price,
    :liquidation_price,
    :margin_mode,
    :isolated,
    :hedged,
    :maintenance_margin,
    :maintenance_margin_percentage,
    :initial_margin,
    :initial_margin_percentage,
    :margin_ratio,
    :last_update_timestamp,
    :last_price,
    :stop_loss_price,
    :take_profit_price,
    :percentage,
    :margin,
    :info
  ]

  @doc "Returns true if the position is long."
  @spec long?(t()) :: boolean()
  def long?(%__MODULE__{side: "long"}), do: true
  def long?(%__MODULE__{}), do: false

  @doc "Returns true if the position is short."
  @spec short?(t()) :: boolean()
  def short?(%__MODULE__{side: "short"}), do: true
  def short?(%__MODULE__{}), do: false

  @doc "Returns true if the position has positive unrealized PnL."
  @spec profitable?(t()) :: boolean()
  def profitable?(%__MODULE__{unrealized_pnl: pnl}) when is_number(pnl), do: pnl > 0
  def profitable?(%__MODULE__{}), do: false

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   symbol: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   side: String.t() | nil,
                   contracts: number() | nil,
                   contract_size: number() | nil,
                   notional: number() | nil,
                   notional_currency: String.t() | nil,
                   base_quantity: number() | nil,
                   leverage: number() | nil,
                   unrealized_pnl: number() | nil,
                   realized_pnl: number() | nil,
                   cumulative_funding: number() | nil,
                   pending_funding: number() | nil,
                   total_fees: number() | nil,
                   net_settlements: number() | nil,
                   collateral: number() | nil,
                   entry_price: number() | nil,
                   mark_price: number() | nil,
                   liquidation_price: number() | nil,
                   margin_mode: String.t() | nil,
                   isolated: boolean() | nil,
                   hedged: boolean() | nil,
                   maintenance_margin: number() | nil,
                   maintenance_margin_percentage: number() | nil,
                   initial_margin: number() | nil,
                   initial_margin_percentage: number() | nil,
                   margin_ratio: number() | nil,
                   last_update_timestamp: integer() | nil,
                   last_price: number() | nil,
                   stop_loss_price: number() | nil,
                   take_profit_price: number() | nil,
                   percentage: number() | nil,
                   margin: number() | nil,
                   info: map() | nil
                 },
                 doc: [
                   id: "Position ID",
                   symbol: "Unified symbol (e.g., BTC/USDT:USDT)",
                   timestamp: "Last update time in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   side: "long or short",
                   contracts: "Number of contracts",
                   contract_size: "Size of one contract",
                   notional: "Absolute position value denominated by notional_currency",
                   notional_currency:
                     "Unified currency code that denominates notional; populated whenever notional is populated on the unified read path",
                   base_quantity:
                     "Absolute base-currency size populated only for Deribit futures from size_currency; nil for Deribit options and other venues",
                   leverage: "Current leverage",
                   unrealized_pnl: "Unrealized profit/loss",
                   realized_pnl: "Realized profit/loss",
                   cumulative_funding: "Funding settled for the position",
                   pending_funding: "Funding not yet settled into cash balance",
                   total_fees: "Fees paid while opening or changing the position",
                   net_settlements: "Net USD paid or received from settlements",
                   collateral: "Collateral amount",
                   entry_price: "Average entry price",
                   mark_price: "Current mark price",
                   liquidation_price: "Estimated liquidation price",
                   margin_mode: "cross or isolated",
                   isolated: "Whether the position uses isolated margin",
                   hedged: "Whether position is in hedge mode",
                   maintenance_margin: "Required maintenance margin",
                   maintenance_margin_percentage: "Maintenance margin as a fraction (0.1 = 10%)",
                   initial_margin: "Required initial margin",
                   initial_margin_percentage: "Initial margin as a fraction (0.1 = 10%)",
                   margin_ratio: "Current margin ratio as a fraction (0.1 = 10%)",
                   last_update_timestamp: "Last update timestamp",
                   last_price: "Last traded price",
                   stop_loss_price: "Stop loss price",
                   take_profit_price: "Take profit price",
                   percentage: "PnL in percent points (10 = 10%)",
                   margin: "Position margin",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Position unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
