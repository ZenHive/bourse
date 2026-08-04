defmodule Bourse.OracleLabelTest do
  use ExUnit.Case, async: true

  alias Bourse.OracleLabel

  @manifest_path "test/fixtures/responses/_manifest.json"
  @external_resource @manifest_path
  @recording_manifest @manifest_path |> File.read!() |> Jason.decode!()

  test "tier-1 labels name venue, method, and capture date from the recording manifest" do
    recording =
      Enum.find(@recording_manifest["recordings"], fn recording ->
        recording["venue"] == "deribit" and recording["method"] == "fetch_markets"
      end)

    assert is_map(recording)

    identity = OracleLabel.tier1_identity(recording)
    label = OracleLabel.tier1_label(recording)

    assert identity =~ "reality tier 1"
    assert identity =~ "deribit"
    assert identity =~ "fetch_markets"
    assert identity =~ recording["capture_date"]
    assert identity =~ recording["host"]
    assert identity =~ recording["endpoint"]
    assert label == "Oracle: #{identity}"
  end

  test "tier-1 suite banner lists manifest identities for real-recordings replay paths" do
    banner =
      OracleLabel.tier1_suite_banner(
        ["deribit/fetch_markets.json", "binance/fetch_balance.json"],
        @recording_manifest,
        @manifest_path
      )

    assert banner =~ "verified reality"
    assert banner =~ "real-recordings corpus"
    assert banner =~ "deribit fetch_markets"
    assert banner =~ "binance fetch_balance"
  end

  test "tier-1 labels fail when the recording manifest cannot identify the oracle" do
    fixture = %{"exchange" => "deribit", "method" => "missing_recording"}

    assert_raise ArgumentError, ~r/recording manifest .* has no entry for deribit\/missing_recording/, fn ->
      OracleLabel.tier1_label_from_fixture(fixture, @recording_manifest, @manifest_path)
    end

    assert_raise ArgumentError, ~r/recording manifest .* has no entry for deribit\/missing_recording.json/, fn ->
      OracleLabel.tier1_suite_banner(
        ["deribit/missing_recording.json"],
        @recording_manifest,
        @manifest_path
      )
    end
  end

  test "exchange-acceptance labels name the accepted request" do
    label =
      OracleLabel.exchange_acceptance_label(%{
        "acceptance" => %{
          "business_success" => "retCode=0 with orderId",
          "capture_date" => "2026-07-22",
          "endpoint" => "v5/order/create",
          "host" => "api-demo.bybit.com",
          "http_status" => 200,
          "method" => "create_order",
          "venue" => "bybit"
        }
      })

    assert label =~ "exchange-acceptance tier 1"
    assert label =~ "bybit create_order accepted 2026-07-22"
    assert label =~ "HTTP 200"
    assert label =~ "retCode=0 with orderId"
  end

  test "tier-1 identity requires a manifest capture date" do
    assert_raise ArgumentError, ~r/recording missing capture date/, fn ->
      OracleLabel.tier1_identity(%{"venue" => "deribit", "method" => "fetch_markets"})
    end
  end
end
