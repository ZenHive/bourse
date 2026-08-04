defmodule Bourse.Currency do
  @moduledoc """
  Unified currency data.

  Describes a currency or token supported by an exchange, including
  deposit/withdraw capabilities and network information.

  ## Fields

    * `id` - Exchange-specific currency ID
    * `code` - Unified currency code (e.g., "BTC")
    * `name` - Full currency name
    * `numeric_id` - Numeric ID (some exchanges)
    * `precision` - Decimal precision
    * `type` - "crypto" or "fiat"
    * `active` - Whether the currency (or a network under `networks`) is considered
      usable. When derived from per-chain deposit/withdraw flags, the rollup is an
      **authored per-venue decision** (`active_requires_both` on the currency field
      map): `true` requires both directions, `false` accepts either. First-class
      venues must declare the flag; there is no silent default for them (task 482).
      Some venues (e.g. Binance coin-level) set currency `active` from a non-chain
      field such as `trading` — see that venue's carve register.
    * `deposit` - Whether deposits are enabled
    * `withdraw` - Whether withdrawals are enabled
    * `fee` - Default withdrawal fee
    * `fees` - Per-network withdrawal-fee map (Bourse `fees`, `%{}` when none)
    * `limits` - Amount/withdraw/deposit min/max limits (Bourse `limits`)
    * `networks` - Network-specific deposit/withdraw info
    * `info` - Raw exchange response

  Mirrors Bourse's `safeCurrencyStructure` key set exactly (no `margin` — that is a
  non-canonical extra only a few venues emit; the unified struct stays to the
  shared 14-key shape the static-response fixtures assert against).
  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          code: String.t() | nil,
          name: String.t() | nil,
          numeric_id: integer() | nil,
          precision: number() | nil,
          type: String.t() | nil,
          active: boolean() | nil,
          deposit: boolean() | nil,
          withdraw: boolean() | nil,
          fee: number() | nil,
          fees: map(),
          limits: map() | nil,
          networks: map() | nil,
          info: map() | nil
        }

  defstruct [
    :id,
    :code,
    :name,
    :numeric_id,
    :precision,
    :type,
    :active,
    :deposit,
    :withdraw,
    :fee,
    :info,
    # Currency defaults: empty fee map and an all-nil
    # amount/withdraw/deposit limits shape, present on every currency.
    :networks,
    # `limits` is venue-authored (its shape varies: deribit amount/withdraw/deposit,
    # derive deposit/withdraw) — default nil, set by each spec's currency field map.
    :limits,
    # Currency structs always carry an empty fee map by default.
    fees: %{}
  ]

  @json_schema schema(
                 %{
                   id: String.t() | nil,
                   code: String.t() | nil,
                   name: String.t() | nil,
                   numeric_id: integer() | nil,
                   precision: number() | nil,
                   type: String.t() | nil,
                   active: boolean() | nil,
                   deposit: boolean() | nil,
                   withdraw: boolean() | nil,
                   fee: number() | nil,
                   fees: map(),
                   limits: map() | nil,
                   networks: map(),
                   info: map() | nil
                 },
                 doc: [
                   id: "Exchange-specific currency ID",
                   code: "Unified currency code (e.g., BTC)",
                   name: "Full currency name",
                   numeric_id: "Numeric ID (some exchanges)",
                   precision: "Decimal precision",
                   type: "crypto or fiat",
                   active: "Whether trading/deposit/withdraw is enabled",
                   deposit: "Whether deposits are enabled",
                   withdraw: "Whether withdrawals are enabled",
                   fee: "Default withdrawal fee",
                   fees: "Per-network withdrawal-fee map",
                   limits: "Amount/withdraw/deposit min/max limits",
                   networks: "Network-specific deposit/withdraw info",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Currency unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
