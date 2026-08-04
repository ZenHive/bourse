defmodule Bourse.DepositWithdrawFee do
  @moduledoc """
  Unified deposit/withdraw fee data.

  Describes the fee schedule for deposits and withdrawals of a currency,
  optionally broken down by network.

  ## Fields

    * `withdraw` - Withdrawal fee info: `%{fee: number(), percentage: boolean()}`
    * `deposit` - Deposit fee info: `%{fee: number(), percentage: boolean()}`
    * `networks` - Per-network fee info: `%{network_name => %{withdraw: ..., deposit: ...}}`
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          withdraw: map() | nil,
          deposit: map() | nil,
          networks: map(),
          info: map() | nil
        }

  defstruct [:withdraw, :deposit, :info, networks: %{}]

  @json_schema schema(
                 %{
                   withdraw: map() | nil,
                   deposit: map() | nil,
                   networks: map(),
                   info: map() | nil
                 },
                 doc: [
                   withdraw: "Withdrawal fee info: %{fee: number(), percentage: boolean()}",
                   deposit: "Deposit fee info: %{fee: number(), percentage: boolean()}",
                   networks: "Per-network fee info: %{network_name => %{withdraw: ..., deposit: ...}}",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the DepositWithdrawFee unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
