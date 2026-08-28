defmodule Bourse.BinanceQueryArrayIntegrationTest do
  use ExUnit.Case, async: true

  @moduletag :network

  # Queries are hand-built into the URL on purpose — never route through Req's
  # `:params` here. This test pins the VENUE's answer to known wire bytes, and
  # Req's param encoder owns its own dedup policy (req 0.6 collapsed repeated
  # keys last-value-wins; req 0.7.4 emits them verbatim), so `:params` would
  # make the test track Req instead of binance. The client itself never uses
  # `:params` either — every query is hand-built via `Bourse.Signing.urlencode/1`.
  @endpoint "https://testnet.binance.vision/api/v3/ticker/price"

  test "spot testnet accepts JSON array symbols and rejects repeated keys" do
    encoded_array = URI.encode_www_form(Jason.encode!(["BTCUSDT", "ETHUSDT"]))
    accepted = Req.get!("#{@endpoint}?symbols=#{encoded_array}")

    assert accepted.status == 200
    assert Enum.map(accepted.body, & &1["symbol"]) == ["BTCUSDT", "ETHUSDT"]

    rejected = Req.get!("#{@endpoint}?symbols=BTCUSDT&symbols=ETHUSDT")

    assert rejected.status == 400
    # Live 2026-08-28: a genuinely duplicated `symbols` key is rejected with
    # -1101 "Duplicate values for parameter 'symbols'.".
    # The earlier -1100 observation (2026-07-29, "Illegal characters found in
    # parameter 'symbols'") came from req 0.6's last-value-wins dedup: the wire
    # carried only `symbols=ETHUSDT`, and a bare (non-JSON-array) value fails
    # binance's format regex with -1100 — verified live 2026-08-28. The venue
    # never changed; the bytes Req sent did.
    assert rejected.body["code"] == -1101
  end
end
