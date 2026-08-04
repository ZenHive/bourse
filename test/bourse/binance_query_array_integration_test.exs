defmodule Bourse.BinanceQueryArrayIntegrationTest do
  use ExUnit.Case, async: true

  @moduletag :network
  @endpoint "https://testnet.binance.vision/api/v3/ticker/price"

  test "spot testnet accepts JSON array symbols and rejects repeated keys" do
    accepted =
      Req.get!(
        @endpoint,
        params: [symbols: Jason.encode!(["BTCUSDT", "ETHUSDT"])]
      )

    assert accepted.status == 200
    assert Enum.map(accepted.body, & &1["symbol"]) == ["BTCUSDT", "ETHUSDT"]

    rejected = Req.get!(@endpoint, params: [symbols: "BTCUSDT", symbols: "ETHUSDT"])

    assert rejected.status == 400
    # Live 2026-07-29: testnet rejects repeated `symbols` keys with -1100
    # "Illegal characters found in parameter 'symbols'" (was -1101 historically).
    assert rejected.body["code"] == -1100
  end
end
