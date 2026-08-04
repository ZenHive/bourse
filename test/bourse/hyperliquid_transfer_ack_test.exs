defmodule Bourse.HyperliquidTransferAckTest do
  @moduledoc """
  Offline pins for Hyperliquid's bare transfer-ack carve (task 331 / C-T331).

  Venue success is `{"status":"ok","response":{"type":"default"}}` with no
  TransferEntry-shaped payload — see Hyperliquid exchange endpoint docs and
  the Python SDK's usd_class_transfer / sub_account_transfer responses.
  """

  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.TransferEntry
  alias Bourse.Unified.ReadParse

  @ack %{"status" => "ok", "response" => %{"type" => "default"}}

  setup do
    exchange =
      Exchange.new!("hyperliquid",
        credentials: Credentials.new!(api_key: "0xwallet", secret: "0x" <> String.duplicate("ab", 32))
      )

    %{exchange: exchange, module: exchange.module}
  end

  test "successful ack is never classified as an error", %{exchange: exchange, module: module} do
    params = %{
      "code" => "USDC",
      "amount" => 1.5,
      "from_account" => "spot",
      "to_account" => "swap"
    }

    assert {:ok, %TransferEntry{} = entry} =
             ReadParse.parse(
               exchange,
               module,
               :transfer,
               "transfer",
               @ack,
               params,
               :parse_transfer,
               false
             )

    assert entry.status == "ok"
    assert entry.currency == "USDC"
    assert entry.amount == 1.5
    assert entry.from_account == "spot"
    assert entry.to_account == "swap"
    assert entry.info["status"] == "ok"
    assert entry.info["response"] == %{"type" => "default"}
  end

  test "failed venue status still surfaces through the struct, not as all-nil error", %{
    exchange: exchange,
    module: module
  } do
    body = %{"status" => "err", "response" => %{"type" => "default"}}

    assert {:ok, %TransferEntry{status: "failed"}} =
             ReadParse.parse(
               exchange,
               module,
               :transfer,
               "transfer",
               body,
               %{
                 "code" => "USDC",
                 "amount" => 1,
                 "from_account" => "spot",
                 "to_account" => "swap"
               },
               :parse_transfer,
               false
             )
  end
end
