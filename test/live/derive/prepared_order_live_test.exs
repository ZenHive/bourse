defmodule Bourse.Derive.PreparedOrderLiveTest do
  @moduledoc """
  Live Derive v3 testnet pin for `Bourse.Signing.Derive.PreparedOrder`: a
  customer-signed order is accepted exactly as prepared, and the same signature
  over one altered term is refused.

  The wire body carries no `module`, chain id or verifying contract, so the
  venue rebuilds the digest from its own deployment. An accepted signature
  therefore grades the Trade module address and domain this module hashes in,
  and the rejection echoes the module and domain separator the venue used.

  Observed 2026-11-26 on https://testnet.api.derive.xyz/v3: a post-signing
  change to `limit_price` or `max_fee` answers `14014` "Signature invalid for
  message or transaction", with `expected_signer` the owner and a different
  `recovered_signer` in `data`.

  Provider sources (retrieved 2026-11-26):
  https://docs.derive.xyz/authentication/action-signing.md,
  https://docs.derive.xyz/reference/error-codes.md.
  """
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, derive_subaccount_id!: 0, require_credentials!: 2]

  alias Bourse.Error
  alias Bourse.Signing.Crypto
  alias Bourse.Signing.Derive, as: DeriveSigning
  alias Bourse.Signing.Derive.PreparedOrder
  alias Bourse.Test.Journeys.Case, as: Journey

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_derive

  @derive_testnet_url "https://testnet.app.derive.xyz"
  @symbol "BTC/USDC:USDC"
  @instrument "BTC-PERP"
  @amount "0.1"
  @max_fee "200"
  # Ticks above the ticker's `minp`: the band moves with the mark between the
  # ticker read and the post, and a limit outside it is refused as 11013.
  @band_margin_ticks 10
  @testnet_domain_separator "0x24d674cd5f2b9d564691c51e9d88f649b99246a2244dd74ce27b96578d773e85"

  @tag :dangerous
  test "a prepared order signed by the owner rests as submitted; an altered term breaks the signature" do
    credentials = require_credentials!(:derive, url: @derive_testnet_url)

    base =
      build_exchange(:derive,
        credentials: credentials,
        sandbox: true,
        options: %{"subaccount_id" => derive_subaccount_id!()}
      )

    assert {:ok, exchange} = Bourse.load_markets(base)

    {:ok, %{body: %{"result" => instrument}}} =
      Bourse.Derive.public_post_get_instrument(exchange, %{"instrument_name" => @instrument})

    price = resting_bid(exchange, Decimal.new(instrument["tick_size"]))
    prepared = prepare!(credentials, instrument, price)
    signed = Map.put(prepared.body, "signature", sign_digest(prepared.digest, credentials.secret))

    tick = Decimal.new(instrument["tick_size"])
    altered_price = price |> Decimal.new() |> Decimal.add(tick) |> Decimal.to_string(:normal)

    for {term, value} <- [{"limit_price", altered_price}, {"max_fee", "201"}] do
      assert {:error, %Error{type: :invalid_order, code: 14_014, message: message, raw: raw}} =
               Bourse.Derive.private_post_order(exchange, %{signed | term => value}),
             "altered #{term} was not refused as a signature mismatch"

      assert message =~ "Signature invalid for message or transaction"
      data = JSON.decode!(raw["error"]["data"])
      assert data["expected_signer"] == prepared.body["signer"]
      refute data["recovered_signer"] == prepared.body["signer"]
      assert data["module"] == prepared.typed_data["message"]["module"]
      assert data["domain_separator"] == @testnet_domain_separator
    end

    assert {:ok, %{body: %{"result" => %{"order" => order}}}} = Bourse.Derive.private_post_order(exchange, signed)
    on_exit(fn -> Journey.release_order!(exchange, order["order_id"], @symbol) end)

    assert order["order_status"] == "open"
    assert order["nonce"] == prepared.body["nonce"]
    assert order["signer"] == prepared.body["signer"]
    assert order["subaccount_id"] == derive_subaccount_id!()

    for term <- ["limit_price", "amount", "max_fee"] do
      assert Decimal.equal?(Decimal.new(order[term]), Decimal.new(prepared.body[term])),
             "#{term}: venue echoed #{order[term]}, signed #{prepared.body[term]}"
    end
  end

  # A bid inside the venue's price band yet far below the mark, so it rests.
  defp resting_bid(exchange, tick) do
    {:ok, %{body: %{"result" => %{"minp" => minp}}}} =
      Bourse.Derive.public_post_get_ticker(exchange, %{"instrument_name" => @instrument})

    minp
    |> Decimal.new()
    |> Decimal.div(tick)
    |> Decimal.round(0, :ceiling)
    |> Decimal.add(@band_margin_ticks)
    |> Decimal.mult(tick)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp prepare!(credentials, instrument, price) do
    now_ms = System.system_time(:millisecond)

    assert {:ok, prepared} =
             PreparedOrder.prepare(
               %{
                 "subaccount_id" => derive_subaccount_id!(),
                 "nonce" => now_ms * 1_000_000 + :rand.uniform(899_999) + 100_000,
                 "signature_expiry_sec" => div(now_ms, 1_000) + 3_600,
                 "owner" => credentials.api_key,
                 "signer" => DeriveSigning.signer_address(credentials.secret),
                 "base_asset_address" => instrument["base_asset_address"],
                 "base_asset_sub_id" => instrument["base_asset_sub_id"],
                 "instrument_name" => @instrument,
                 "direction" => "buy",
                 "amount" => @amount,
                 "limit_price" => price,
                 "max_fee" => @max_fee
               },
               :testnet
             )

    prepared
  end

  defp sign_digest("0x" <> hex, secret) do
    hex
    |> Base.decode16!(case: :mixed)
    |> Crypto.sign_hash(Crypto.decode_private_key(secret))
    |> Crypto.packed_signature()
  end
end
