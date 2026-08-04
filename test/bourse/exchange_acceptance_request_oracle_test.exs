defmodule Bourse.ExchangeAcceptanceRequestOracleTest do
  use ExUnit.Case, async: true

  alias Bourse.ExchangeAcceptanceFixtures
  alias Bourse.JsonDocument

  @manifest_path "test/fixtures/exchange_accepted_requests/_manifest.json"
  @external_resource @manifest_path
  @manifest JsonDocument.decode_file!(@manifest_path)
  @fixture_paths Enum.map(@manifest["goldens"], &Path.join("test/fixtures/exchange_accepted_requests", &1["path"]))
  @goldens Enum.map(@fixture_paths, &JsonDocument.decode_file!/1)

  for fixture_path <- @fixture_paths do
    @external_resource fixture_path
  end

  @credential_env_names ~w(
    ALPACA_API_KEY
    ALPACA_API_SECRET
    BINANCE_TESTNET_API_KEY
    BINANCE_TESTNET_API_SECRET
    BINANCE_FUTURES_TEST_API_KEY
    BINANCE_FUTURES_TEST_API_SECRET
    BYBIT_DEMO_API_KEY
    BYBIT_DEMO_API_SECRET
    DERIBIT_TESTNET_API_KEY
    DERIBIT_TESTNET_API_SECRET
    OKX_INTL_API_KEY
    OKX_INTL_API_SECRET
    OKX_INTL_PASSPHRASE
    HYPERLIQUID_TESTNET_API_KEY
    HYPERLIQUID_TESTNET_API_SECRET
    LIGHTER_TESTNET_API_PRIVATE_KEY
    DERIVE_TESTNET_API_KEY
    DERIVE_TESTNET_API_SECRET
  )

  test "manifest covers every first-class venue with accepted live evidence" do
    assert ExchangeAcceptanceFixtures.fixture_root() == Path.expand("test/fixtures/exchange_accepted_requests")
    assert ExchangeAcceptanceFixtures.manifest_path() == Path.expand(@manifest_path)
    assert Enum.sort(ExchangeAcceptanceFixtures.load_all!()) == Enum.sort(@goldens)

    assert @manifest["oracle"] == "exchange_acceptance"
    assert @manifest["count"] == length(ExchangeAcceptanceFixtures.profiles())

    assert @manifest["goldens"] |> Enum.map(& &1["venue"]) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(ExchangeAcceptanceFixtures.first_class_venues())

    Enum.each(@manifest["goldens"], fn row ->
      assert row["http_status"] in 200..299
      assert is_binary(row["business_success"]) and row["business_success"] != ""
      assert is_binary(row["capture_date"]) and row["capture_date"] != ""
      assert is_binary(row["endpoint"]) and row["endpoint"] != ""
      assert is_binary(row["host"]) and row["host"] != ""
      assert row["label"] =~ "exchange-acceptance tier 1"

      {_, method} =
        Enum.find(ExchangeAcceptanceFixtures.profiles(), fn {venue, method} ->
          venue == row["venue"] and Atom.to_string(method) == row["method"]
        end)

      assert File.exists?(ExchangeAcceptanceFixtures.fixture_path(row["venue"], method))
    end)
  end

  test "offline replay rebuilds every exchange-accepted signed request exactly" do
    Enum.each(@goldens, fn golden ->
      assert :ok = ExchangeAcceptanceFixtures.replay(golden), golden["label"]
    end)
  end

  test "every golden freezes distinct timestamp and nonce overrides" do
    Enum.each(@goldens, fn golden ->
      timestamp_ms = get_in(golden, ["replay", "timestamp_ms_override"])
      nonce = get_in(golden, ["replay", "nonce_override"])

      assert is_integer(timestamp_ms), golden["label"]
      assert is_integer(nonce), golden["label"]
      refute timestamp_ms == nonce, golden["label"]
    end)
  end

  test "a deterministic signature mutation turns the offline gate red" do
    golden = Enum.find(@goldens, &(get_in(&1, ["acceptance", "venue"]) == "deribit"))

    mutated =
      update_in(golden, ["request", "headers"], fn headers ->
        Enum.map(headers, fn
          ["authorization", value] -> ["authorization", value <> "0"]
          header -> header
        end)
      end)

    assert {:error, :accepted_request_regressed} = ExchangeAcceptanceFixtures.replay(mutated)
  end

  test "replay rejects malformed identity before rebuilding a request" do
    golden = hd(@goldens)

    for key <- ~w(method timestamp_ms_override nonce_override) do
      mutated = put_in(golden, ["replay", key], nil)
      assert {:error, :invalid_replay_identity} = ExchangeAcceptanceFixtures.replay(mutated)
    end
  end

  test "goldens contain no configured live credentials" do
    live_material =
      @credential_env_names
      |> Enum.map(&System.get_env/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    assert :ok = ExchangeAcceptanceFixtures.validate_no_material(@goldens, live_material)
  end

  test "material guard inspects maps, tuples, URLs, and encoded request bodies" do
    secret = "live-secret-that-must-never-be-written"

    unsafe = %{
      body: Jason.encode!(%{"nested" => %{"signature" => secret}}),
      headers: [{"authorization", "Bearer #{secret}"}],
      url: "https://example.test/private?signature=#{secret}"
    }

    assert {:error, :sensitive_material_present} =
             ExchangeAcceptanceFixtures.validate_no_material(unsafe, [secret])

    assert :ok = ExchangeAcceptanceFixtures.validate_no_material(unsafe, ["different-secret"])

    assert {:error, :sensitive_material_present} =
             ExchangeAcceptanceFixtures.validate_no_material({["safe", secret]}, [secret])
  end
end
