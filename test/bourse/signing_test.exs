defmodule Bourse.SigningTest do
  use ExUnit.Case, async: true

  alias Bourse.Signing
  alias Bourse.Signing.Request
  alias Bourse.Signing.SignedRequest
  alias Mix.Tasks.Ccxt.Helpers

  # --- Crypto Helpers ---

  describe "hmac_sha256/2" do
    test "produces correct HMAC-SHA256 digest" do
      # Known test vector
      result = Signing.hmac_sha256("test data", "secret_key")
      hex = Signing.encode_hex(result)
      # Verify it's a valid 32-byte (64 hex char) HMAC
      assert byte_size(result) == 32
      assert String.length(hex) == 64
      assert String.match?(hex, ~r/^[0-9a-f]+$/)
    end

    test "different data produces different signatures" do
      sig1 = Signing.hmac_sha256("data1", "secret")
      sig2 = Signing.hmac_sha256("data2", "secret")
      assert sig1 != sig2
    end

    test "different secrets produce different signatures" do
      sig1 = Signing.hmac_sha256("data", "secret1")
      sig2 = Signing.hmac_sha256("data", "secret2")
      assert sig1 != sig2
    end
  end

  describe "hmac_sha384/2" do
    test "produces 48-byte digest" do
      result = Signing.hmac_sha384("test", "key")
      assert byte_size(result) == 48
    end
  end

  describe "hmac_sha512/2" do
    test "produces 64-byte digest" do
      result = Signing.hmac_sha512("test", "key")
      assert byte_size(result) == 64
    end
  end

  describe "sha256/1" do
    test "produces correct SHA256 hash" do
      result = Signing.sha256("test")
      assert byte_size(result) == 32
    end

    test "empty string produces valid hash" do
      result = Signing.sha256("")
      assert byte_size(result) == 32
    end
  end

  describe "sha512/1" do
    test "produces correct SHA512 hash" do
      result = Signing.sha512("test")
      assert byte_size(result) == 64
    end
  end

  describe "encode_hex/1" do
    test "encodes binary as lowercase hex" do
      assert Signing.encode_hex(<<255, 0, 171>>) == "ff00ab"
    end

    test "empty binary returns empty string" do
      assert Signing.encode_hex(<<>>) == ""
    end
  end

  describe "encode_base64/1" do
    test "encodes binary as base64" do
      assert Signing.encode_base64("hello") == Base.encode64("hello")
    end
  end

  describe "decode_base64/1" do
    test "decodes base64 string" do
      encoded = Base.encode64("hello world")
      assert Signing.decode_base64(encoded) == "hello world"
    end

    test "roundtrips with encode_base64" do
      original = :crypto.strong_rand_bytes(32)
      assert original == original |> Signing.encode_base64() |> Signing.decode_base64()
    end
  end

  describe "urlencode/1" do
    test "sorts params alphabetically" do
      result = Signing.urlencode(%{"z" => "1", "a" => "2", "m" => "3"})
      assert result == "a=2&m=3&z=1"
    end

    test "returns empty string for nil" do
      assert Signing.urlencode(nil) == ""
    end

    test "returns empty string for empty map" do
      assert Signing.urlencode(%{}) == ""
    end

    test "handles atom keys" do
      result = Signing.urlencode(%{beta: "2", alpha: "1"})
      assert result == "alpha=1&beta=2"
    end

    # Task 286 — pin space → %20 (not URI.encode_query's www-form +).
    # Venue docs (Huobi/HTX Signature Method): "Use UTF-8 encoding and URL encoded,
    # the hex must be upper case. … The space should be encoded as '%20'."
    # https://huobiapi.github.io/docs/spot/v1/en/#authentication
    # Confirmed against that source (not CCXT JS alone). No first-class venue
    # requires www-form + for the signed canonical query (carve C21).
    test "encodes spaces as %20, not application/x-www-form-urlencoded +" do
      assert URI.encode_query(%{"a" => "x y"}) == "a=x+y",
             "baseline: Elixir URI.encode_query still uses + (the bug class we diverge from)"

      result = Signing.urlencode(%{"note" => "hello world", "a" => "1"})
      assert result == "a=1&note=hello%20world"
      refute String.contains?(result, "+")

      # Same path for ordered pair lists (HmacRecipe insertion order).
      assert Signing.encode_query_pairs([{"label", "task 286"}]) == "label=task%20286"
    end

    test "encodes colon with uppercase hex (Huobi Timestamp example shape)" do
      # Huobi docs example: Timestamp=2017-05-11T15%3A19%3A30
      result = Signing.urlencode(%{"Timestamp" => "2017-05-11T15:19:30"})
      assert result == "Timestamp=2017-05-11T15%3A19%3A30"
    end

    test "encodes scalar list params with empty-bracket keys (Deribit dialect)" do
      result = Signing.urlencode(%{"ids" => ["ETH-1", "ETH-2"], "a" => "1"})
      assert result == "a=1&ids%5B%5D=ETH-1&ids%5B%5D=ETH-2"
    end

    test "encodes channels list without crashing (Deribit subscribe shape)" do
      result = Signing.urlencode(%{"channels" => ["trades.BTC-PERPETUAL.raw", "ticker.BTC-PERPETUAL.raw"]})
      assert result == "channels%5B%5D=trades.BTC-PERPETUAL.raw&channels%5B%5D=ticker.BTC-PERPETUAL.raw"
    end

    test "encode_query_pairs/2 supports bare-key array repeat" do
      result = Signing.encode_query_pairs([{"ids", ["a", "b"]}], array_style: :repeat)
      assert result == "ids=a&ids=b"
    end

    test "raises naming the param for nested list-of-maps values" do
      assert_raise ArgumentError, ~r/unsupported nested query param "trades"/, fn ->
        Signing.urlencode(%{
          "trades" => [%{"instrument_name" => "BTC-PERPETUAL", "amount" => 1}]
        })
      end
    end

    test "raises naming the param for nested list-of-lists values" do
      assert_raise ArgumentError, ~r/unsupported nested query param "ids": .*got list/, fn ->
        Signing.urlencode(%{"ids" => [["a", "b"]]})
      end
    end

    test "returns empty string for empty pair list" do
      assert Signing.urlencode([]) == ""
    end

    test "preserves caller order for a pair list instead of sorting" do
      assert Signing.urlencode([{"b", "2"}, {"a", "1"}]) == "b=2&a=1"
    end

    test "expands list params given as a pair list" do
      assert Signing.urlencode([{"ids", ["a", "b"]}]) == "ids%5B%5D=a&ids%5B%5D=b"
    end
  end

  describe "urlencode_raw/1" do
    test "sorts params but does not URI-encode values" do
      result = Signing.urlencode_raw(%{"b" => "hello world", "a" => "test"})
      assert result == "a=test&b=hello world"
    end

    test "returns empty string for nil" do
      assert Signing.urlencode_raw(nil) == ""
    end

    test "returns empty string for empty map" do
      assert Signing.urlencode_raw(%{}) == ""
    end

    test "expands scalar list params with unencoded empty-bracket keys" do
      assert Signing.urlencode_raw(%{"ids" => ["a", "b"], "c" => "1"}) == "c=1&ids[]=a&ids[]=b"
    end

    test "raises naming the param for nested list values" do
      assert_raise ArgumentError, ~r/unsupported nested query param "trades"/, fn ->
        Signing.urlencode_raw(%{"trades" => [%{"amount" => 1}]})
      end
    end
  end

  describe "timestamp_ms/0" do
    test "returns current time in milliseconds" do
      ts = Signing.timestamp_ms()
      assert is_integer(ts)
      # Should be roughly current time (after 2020)
      assert ts > 1_577_836_800_000
    end
  end

  describe "timestamp_seconds/0" do
    test "returns current time in seconds" do
      ts = Signing.timestamp_seconds()
      assert is_integer(ts)
      assert ts > 1_577_836_800
    end
  end

  describe "timestamp_iso8601/0" do
    test "returns valid ISO8601 string" do
      ts = Signing.timestamp_iso8601()
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(ts)
    end
  end

  describe "timestamp_*_from_config/1 (override branches)" do
    test "timestamp_ms_from_config returns binary timestamp when present" do
      assert "2026-01-01T00:00:00.000Z" = Signing.timestamp_ms_from_config(%{timestamp: "2026-01-01T00:00:00.000Z"})
    end

    test "timestamp_seconds_from_config returns binary timestamp when present" do
      assert "1700000000" = Signing.timestamp_seconds_from_config(%{timestamp: "1700000000"})
    end

    test "timestamp_seconds_from_config uses current seconds without an override" do
      timestamp = Signing.timestamp_seconds_from_config(%{})
      assert is_integer(timestamp)
      assert timestamp > 0
    end

    test "timestamp_iso8601_from_config renders override ms as iso" do
      ts = Signing.timestamp_iso8601_from_config(%{timestamp_ms_override: 1_704_000_000_000})
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(ts)
    end

    test "nonce_from_config returns override when set" do
      assert 12_345 = Signing.nonce_from_config(%{nonce_override: 12_345}, fn -> 999 end)
    end
  end

  # --- Introspection ---

  describe "patterns/0" do
    test "returns deterministic built-in patterns only" do
      patterns = Signing.patterns()
      assert length(patterns) == 8
      assert :hmac_sha256_query in patterns
      assert :hmac_sha256_headers in patterns
      assert :hmac_sha256_iso_passphrase in patterns
      assert :deribit in patterns
      assert :hyperliquid in patterns
      assert :derive in patterns
      assert :lighter in patterns
      assert :api_key_secret_headers in patterns
      refute :custom in patterns
      refute :unsupported in patterns
    end

    test "every declared pattern routes to at least one runtime venue" do
      declared = MapSet.new(Signing.patterns())
      routed = MapSet.new(Helpers.signing_results(), fn {_id, pattern, _config} -> pattern end)

      orphaned =
        declared
        |> MapSet.difference(routed)
        |> MapSet.to_list()
        |> Enum.sort()

      assert orphaned == [],
             "declared signing patterns route to zero supported venues: #{inspect(orphaned)}"
    end

    test "every runtime venue resolves to a declared pattern" do
      results = Helpers.signing_results()
      declared = MapSet.new(Signing.patterns())
      expected_venues = MapSet.new(Bourse.Spec.exchanges())
      resolved_venues = MapSet.new(results, &elem(&1, 0))

      undeclared =
        results
        |> Enum.reject(fn
          {id, nil, _config} ->
            spec = Bourse.Spec.load!(id)
            spec["auth"]["authenticated_sections"] == [] and spec["auth"]["signing_pattern"] == nil

          {_id, pattern, _config} ->
            MapSet.member?(declared, pattern)
        end)
        |> Enum.map(fn {id, pattern, _config} -> {id, pattern} end)
        |> Enum.sort()

      public_only = for {id, nil, _config} <- results, do: id

      assert resolved_venues == expected_venues
      assert public_only == ["coinbaseexchange"]

      assert undeclared == [],
             "supported venues resolve to undeclared signing patterns: #{inspect(undeclared)}"
    end
  end

  describe "pattern?/1" do
    test "returns true for valid patterns" do
      assert Signing.pattern?(:hmac_sha256_query)
      assert Signing.pattern?(:deribit)
      refute Signing.pattern?(:custom)
      refute Signing.pattern?(:unsupported)
    end

    test "returns false for invalid patterns" do
      refute Signing.pattern?(:unknown)
      refute Signing.pattern?(:hmac_sha1)
    end
  end

  describe "module_for_pattern/1" do
    test "returns correct module for each pattern" do
      assert Signing.module_for_pattern(:hmac_sha256_query) == Bourse.Signing.HmacSha256Query
      assert Signing.module_for_pattern(:hmac_sha256_headers) == Bourse.Signing.HmacSha256Headers
      assert Signing.module_for_pattern(:hmac_sha256_iso_passphrase) == Bourse.Signing.HmacSha256Iso
      assert Signing.module_for_pattern(:deribit) == Bourse.Signing.Deribit
      assert Signing.module_for_pattern(:hyperliquid) == Bourse.Signing.Hyperliquid
      assert Signing.module_for_pattern(:derive) == Bourse.Signing.Derive
      assert Signing.module_for_pattern(:lighter) == Bourse.Signing.Lighter
      assert Signing.module_for_pattern(:api_key_secret_headers) == Bourse.Signing.ApiKeySecretHeaders
      assert Signing.module_for_pattern(:custom) == nil
      assert Signing.module_for_pattern(:unsupported) == nil
    end

    test "returns nil for unknown pattern" do
      assert Signing.module_for_pattern(:unknown) == nil
    end
  end

  # --- Dispatcher ---

  describe "sign/4 dispatch" do
    setup do
      credentials = %Bourse.Credentials{api_key: "test_key", secret: "test_secret"}

      request = %{
        method: :get,
        path: "/v5/market/tickers",
        body: nil,
        params: %{"category" => "spot"}
      }

      %{credentials: credentials, request: request}
    end

    test "dispatches to each built-in pattern", %{request: req} do
      # Venue-specific first-party patterns have dedicated domain tests.
      for pattern <- Signing.patterns(), pattern not in [:hyperliquid, :derive, :lighter] do
        creds = %Bourse.Credentials{api_key: "test_key", secret: "test_secret"}
        config = build_config_for_pattern(pattern)
        result = Signing.sign(pattern, req, creds, config)

        assert is_binary(result.url), "#{pattern}: url should be a string"
        assert result.method == :get, "#{pattern}: method should be preserved"
        assert is_list(result.headers), "#{pattern}: headers should be a list"

        assert Enum.all?(result.headers, fn {k, v} -> is_binary(k) and is_binary(v) end),
               "#{pattern}: headers should be {string, string} tuples"
      end
    end
  end

  describe "request and signed_request structs" do
    test "Request enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Request, path: "/x")
      end
    end

    test "SignedRequest enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(SignedRequest, url: "/x")
      end
    end

    test "sign accepts map requests and returns SignedRequest" do
      req = %{method: :get, path: "/x", body: nil, params: %{}}
      creds = %Bourse.Credentials{api_key: "k", secret: "s"}

      assert %SignedRequest{} =
               Signing.sign(:hmac_sha256_query, req, creds, %{})
    end

    test "sign accepts Request struct input" do
      req = %Request{method: :get, path: "/x"}
      creds = %Bourse.Credentials{api_key: "k", secret: "s"}

      assert %SignedRequest{method: :get} =
               Signing.sign(:hmac_sha256_query, req, creds, %{})
    end
  end

  describe "signing telemetry" do
    setup do
      parent = self()
      ref = make_ref()
      handler_id = "signing-telemetry-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [[:bourse, :signing, :sign]],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits :sign event with duration on success path" do
      req = %{method: :get, path: "/v5/market/tickers", body: nil, params: %{"category" => "spot"}}
      creds = %Bourse.Credentials{api_key: "k", secret: "s"}
      config = %{}
      _ = Signing.sign(:hmac_sha256_query, req, creds, config)

      assert_received {:telemetry, [:bourse, :signing, :sign], %{duration: d}, %{pattern: :hmac_sha256_query}}
      assert is_integer(d)
    end
  end

  # Builds minimal config for each pattern to avoid crashes
  defp build_config_for_pattern(:api_key_secret_headers), do: %{api_key_header: "API-KEY", secret_header: "API-SECRET"}
  defp build_config_for_pattern(_), do: %{}
end
