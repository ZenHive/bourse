defmodule Bourse.ExchangeTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.HTTP.Errors
  alias Bourse.Spec
  alias Mix.Tasks.Ccxt.Helpers

  describe "new/2 basic construction" do
    test "creates exchange with just an ID (public-only)" do
      assert {:ok, exchange} = Exchange.new("bybit")
      assert exchange.id == "bybit"
      assert exchange.name == "Bybit"
      assert is_nil(exchange.credentials)
      assert exchange.sandbox == false
    end

    test "accepts atom exchange ID" do
      assert {:ok, exchange} = Exchange.new(:bybit)
      assert exchange.id == "bybit"
      assert exchange.name == "Bybit"
    end

    test "populates rate_limit_ms from spec" do
      {:ok, exchange} = Exchange.new("bybit")
      assert exchange.rate_limit_ms == 20

      {:ok, exchange} = Exchange.new("okx")
      assert is_number(exchange.rate_limit_ms)
      assert exchange.rate_limit_ms > 100
    end

    test "populates Bourse network options from the venue spec" do
      assert {:ok, exchange} = Exchange.new("okx")
      assert exchange.network_options["networksById"]["ERC20"] == "ERC20"
    end

    test "populates hostname from spec" do
      {:ok, exchange} = Exchange.new("bybit")
      assert exchange.hostname == "bybit.com"
    end

    test "populates has capabilities from derived capabilities.has" do
      {:ok, exchange} = Exchange.new("bybit")
      assert is_map(exchange.has)
      assert exchange.has["fetchTicker"] == true
      refute Map.has_key?(exchange.has, "__proto__")
    end

    test "populates timeframes from derived capabilities.timeframes" do
      {:ok, exchange} = Exchange.new("bybit")
      assert %{"1h" => "60", "1m" => "1"} = Map.take(exchange.timeframes, ["1h", "1m"])
      assert Exchange.timeframes(exchange) == exchange.timeframes
      assert %{"1h" => "60"} = Bourse.timeframes(exchange)
    end

    test "gate: resynced corpus includes static trading fees for a first-class venue" do
      spec = Spec.load!("binance")

      assert get_in(spec, ["fees", "trading", "maker"]) == 0.001
      assert get_in(spec, ["fees", "trading", "taker"]) == 0.001
    end

    test "populates static default fees from derived fees section" do
      {:ok, exchange} = Exchange.new("binance")

      assert exchange.fees == Exchange.fees(exchange)
      assert exchange.fees == Bourse.fees(exchange)

      assert %Bourse.TradingFee{
               maker: 0.001,
               taker: 0.001,
               percentage: true,
               tier_based: false
             } = exchange.fees.trading.fee

      assert exchange.fees.trading.maker == 0.001
      assert exchange.fees.trading.taker == 0.001
      assert exchange.fees.trading.percentage == true
      assert exchange.fees.trading.tier_based == false
      assert exchange.fees.trading.fee_side == "get"

      assert %Bourse.DepositWithdrawFee{withdraw: %{}, deposit: %{}} = exchange.fees.funding
    end

    test "populates static linear and inverse trading fees" do
      {:ok, exchange} = Exchange.new("binance")

      assert %Bourse.TradingFee{
               maker: 0.0002,
               taker: 0.0005,
               percentage: true,
               tier_based: true
             } = exchange.fees.linear.trading.fee

      assert exchange.fees.linear.trading.fee_side == "quote"

      assert %Bourse.TradingFee{
               maker: 0.0001,
               taker: 0.0005,
               percentage: true,
               tier_based: true
             } = exchange.fees.inverse.trading.fee

      assert exchange.fees.inverse.trading.fee_side == "base"
    end

    test "preserves tier arrays in source volume order" do
      spec = Spec.load!("binance")
      source_tiers = get_in(spec, ["fees", "linear", "trading", "tiers", "maker"])

      {:ok, exchange} = Exchange.new("binance")

      assert exchange.fees.linear.trading.tiers.maker == source_tiers

      assert Enum.map(exchange.fees.linear.trading.tiers.maker, &List.first/1) ==
               [0, 250, 2500, 7500, 22_500, 50_000, 100_000, 200_000, 400_000, 750_000]
    end

    test "nil static fees are exposed cleanly" do
      exchange = struct!(Exchange, id: "test", name: "Test", fees: nil)

      assert Exchange.fees(exchange) == nil
      assert Bourse.fees(exchange) == nil
    end

    test "gate: resynced corpus includes derived config section for a first-class venue" do
      spec = Spec.load!("binance")
      config = spec["config"]

      assert is_map(config["credentials"])
      assert config["credentials"] != %{}

      # at least one of limits/status/routing is populated
      assert is_map(config["limits"]) or is_map(config["status"]) or is_map(config["routing"])
      assert config["status"]["status"] == "ok"
    end

    test "re-points required_credentials to derived config.credentials (parity with raw)" do
      {:ok, exchange} = Exchange.new("binance")

      spec = Spec.load!("binance")
      raw = get_in(spec, ["raw", "describe", "requiredCredentials"])
      derived = get_in(spec, ["config", "credentials"])

      # derived source matches the raw describe key (re-point is faithful)...
      assert derived == raw
      # ...and the struct reads from the derived source
      assert exchange.required_credentials == derived
      assert exchange.required_credentials["apiKey"] == true
      assert exchange.required_credentials["secret"] == true
    end

    test "exposes config limits/status/routing/flags on the struct" do
      {:ok, exchange} = Exchange.new("binance")

      assert is_map(exchange.config)
      assert exchange.config == Exchange.config(exchange)
      assert exchange.config == Bourse.config(exchange)

      assert Exchange.limits(exchange) == exchange.config["limits"]
      assert Exchange.status(exchange) == exchange.config["status"]
      assert Exchange.routing(exchange) == exchange.config["routing"]
      assert Exchange.flags(exchange) == exchange.config["flags"]

      assert Exchange.status(exchange)["status"] == "ok"
      assert Exchange.flags(exchange)["dex"] == false
      # binance carries an accountsByType routing map
      assert is_map(Exchange.routing(exchange)["accountsByType"])
      assert Exchange.routing(exchange)["accountsByType"]["spot"] == "MAIN"
    end

    test "folds urls doc-set into the doc_urls surface" do
      {:ok, exchange} = Exchange.new("binance")

      assert exchange.doc_urls == Exchange.doc_urls(exchange)
      assert exchange.doc_urls == Bourse.doc_urls(exchange)

      for key <- ~w(logo www doc fees api_management) do
        assert Map.has_key?(exchange.doc_urls, key), "missing doc-set url: #{key}"
      end

      assert exchange.doc_urls["www"] == "https://www.binance.com"
      # call URLs (urls.api) are not folded into the doc-set surface
      refute Map.has_key?(exchange.doc_urls, "api")
    end

    test "config accessors return empty maps on a bare struct" do
      exchange = struct!(Exchange, id: "test", name: "Test")

      assert Exchange.config(exchange) == %{}
      assert Exchange.limits(exchange) == %{}
      assert Exchange.status(exchange) == %{}
      assert Exchange.routing(exchange) == %{}
      assert Exchange.flags(exchange) == %{}
      assert Exchange.doc_urls(exchange) == %{}
    end

    test "populates features matrix from derived capabilities.features" do
      {:ok, exchange} = Exchange.new("binance")
      assert is_map(exchange.features)
      assert is_map(exchange.features["spot"])
      assert is_map(exchange.features["spot"]["createOrder"])
    end

    test "gate: first-class venues have populated capabilities.has and timeframes" do
      for id <- ["binance", "okx"] do
        spec = Spec.load!(id)
        assert is_map(spec["capabilities"]["has"])
        assert map_size(spec["capabilities"]["has"]) > 0
        assert is_map(spec["capabilities"]["timeframes"])
        assert map_size(spec["capabilities"]["timeframes"]) > 0
      end
    end

    test "nil features is graceful when upstream omits capabilities.features" do
      {:ok, exchange} = Exchange.new("derive")
      assert exchange.features == nil
      assert Exchange.has?(exchange, "fetchTicker")
    end

    test "populates required_credentials" do
      {:ok, exchange} = Exchange.new("bybit")
      assert exchange.required_credentials["apiKey"] == true
      assert exchange.required_credentials["secret"] == true
      assert exchange.required_credentials["password"] == false
    end

    test "stores lean spec without api endpoints" do
      {:ok, exchange} = Exchange.new("bybit")
      refute Map.has_key?(exchange.spec, "api")
      assert Map.has_key?(exchange.spec, "rateLimit")
      assert Map.has_key?(exchange.spec, "has")
    end

    test "populates error_codes from spec exceptions" do
      {:ok, exchange} = Exchange.new("bybit")
      assert is_map(exchange.error_codes)
      assert map_size(exchange.error_codes) > 0
      # All values should be error type atoms
      assert Enum.all?(exchange.error_codes, fn {_k, v} -> is_atom(v) end)
    end

    test "market-scoped error codes override top-level codes without flattening conflicts" do
      exchange = Exchange.new!("binancecoinm")

      assert Exchange.error_codes_for(exchange, "inverse")["-2019"] == :insufficient_funds
      assert Exchange.error_codes_for(exchange, "linear")["-2019"] == :insufficient_funds
      assert Exchange.error_codes_for(exchange, "portfolioMargin")["-2019"] == :operation_failed

      assert exchange.error_codes["-4061"] == :operation_failed
      assert Exchange.error_codes_for(exchange, "option")["-4061"] == :exchange_error
      assert Exchange.error_codes_for(exchange, "portfolioMargin")["-4061"] == :invalid_order
    end

    test "Binance and USD-M explicitly keep heterogeneous scopes outside the authored slice" do
      for venue <- ~w(binance binanceusdm) do
        spec = Spec.load!(venue)
        authored = get_in(spec, ["errors", "handle_errors", "exceptions"])
        raw = get_in(spec, ["raw", "describe", "exceptions"])

        assert Map.keys(authored) == ["exact"]

        for scope <- ~w(inverse linear option portfolioMargin spot) do
          assert match?(%{"exact" => exact} when is_map(exact), raw[scope])
        end

        exchange = Exchange.new!(venue)
        assert Exchange.error_codes_for(exchange, "linear")["-2019"] == :insufficient_funds
      end
    end

    test "authored exception_scopes project every Binance-family base URL" do
      for venue <- ~w(binance binancecoinm binanceusdm),
          sandbox <- [false, true] do
        exchange = Exchange.new!(venue, sandbox: sandbox)
        declaration = get_in(Spec.load!(venue), ["errors", "handle_errors", "exception_scopes"])

        for {section, url} <- base_url_entries(exchange.base_urls) do
          assert Exchange.error_scope(exchange, url) == Map.fetch!(declaration, section)
        end
      end
    end

    test "non-binance-family venues resolve every base URL to no exception scope" do
      non_binance = Spec.exchanges() -- ~w(binance binancecoinm binanceusdm)

      assert length(non_binance) == 8

      for venue <- non_binance do
        exchanges =
          if venue == "coinbaseexchange" do
            [Exchange.new!(venue)]
          else
            [Exchange.new!(venue), Exchange.new!(venue, sandbox: true)]
          end

        for exchange <- exchanges, {_section, url} <- base_url_entries(exchange.base_urls) do
          assert Exchange.error_scope(exchange, url) == nil,
                 "#{venue} unexpectedly scoped #{inspect(url)} as #{inspect(Exchange.error_scope(exchange, url))}"
        end
      end
    end

    test "error scope is never inferred from bare URL text without an authored projection" do
      exchange = Exchange.new!("bybit")
      assert exchange.spec["error_scopes"] == %{}
      assert Exchange.error_scope(exchange, "https://api.bybit.com") == nil
      assert Exchange.error_scope(exchange, "https://api.alpaca.markets") == nil
      assert Exchange.error_scope(exchange, "https://demo-dapi.binance.com/dapi/v1") == nil
    end

    test "every authored error code is reachable by classification in its declared scope" do
      for venue <- Spec.exchanges(),
          spec = Spec.load!(venue),
          exceptions = get_in(spec, ["errors", "handle_errors", "exceptions"]) || %{},
          {submap, scope, code} <- authored_exception_codes(exceptions) do
        exchange = Exchange.new!(venue)
        scoped_exchange = Exchange.with_error_scope(exchange, scope)

        assert Map.has_key?(scoped_exchange.error_codes, code),
               "#{venue} exceptions.#{submap} code #{code} is unreachable"

        field = List.first(scoped_exchange.error_code_fields) || "code"
        body = %{field => code, "msg" => "authored exception reachability probe"}
        expected_type = scoped_exchange.error_codes[code]

        assert {:error, %Error{type: ^expected_type}} =
                 Errors.classify_response(:get, 400, %{}, body, scoped_exchange),
               "#{venue} exceptions.#{submap} code #{code} did not classify"
      end
    end

    test "flat exception maps without an exact key remain reachable" do
      exceptions =
        "deribit"
        |> Spec.load!()
        |> get_in(["errors", "handle_errors", "exceptions"])

      refute Map.has_key?(exceptions, "exact")
      assert exceptions["11051"] == "OnMaintenance"

      assert {:error, %Error{type: :exchange_not_available}} =
               Errors.classify_response(
                 :get,
                 400,
                 %{},
                 %{"code" => 11_051, "message" => "system_maintenance"},
                 Exchange.new!("deribit")
               )
    end

    test "populates error_code_fields from spec handle_errors" do
      {:ok, exchange} = Exchange.new("bybit")
      # Bybit's handleErrors() extracts ret_code via safeString2(response, 'ret_code', 'retCode')
      assert "ret_code" in exchange.error_code_fields
      assert "retCode" in exchange.error_code_fields
      # Order preserved — primary field first
      assert Enum.find_index(exchange.error_code_fields, &(&1 == "ret_code")) <
               Enum.find_index(exchange.error_code_fields, &(&1 == "retCode"))
    end

    test "filters dual-role message fields out of error_body_checks" do
      {:ok, exchange} = Exchange.new("binance")

      refute Enum.any?(exchange.error_body_checks, fn check ->
               check.field == "msg" or check.field2 == "msg"
             end)
    end

    test "filters dual-role message fields out of error_code_fields" do
      {:ok, exchange} = Exchange.new("binance")
      assert "code" in exchange.error_code_fields
      refute "msg" in exchange.error_code_fields
    end

    test "gate: resynced corpus includes predicate_limbs on error handlers" do
      spec = Spec.load!("binance")

      assert Enum.any?(spec["endpoints"]["handlers"]["error"], fn
               %{"predicate_limbs" => [_ | _]} -> true
               _ -> false
             end)
    end

    test "populates guarded body error predicates from handler predicate_limbs" do
      {:ok, exchange} = Exchange.new("binance")

      assert Enum.any?(exchange.error_handler_checks, fn check ->
               check.status_guard == {:gte, 400} and
                 check.body_contains == ["LOT_SIZE"] and
                 check.error_type == :invalid_order
             end)
    end

    test "populates http_exceptions from spec" do
      {:ok, exchange} = Exchange.new("bybit")
      assert is_map(exchange.http_exceptions)
      # 401 should map to authentication_error
      assert exchange.http_exceptions["401"] == :authentication_error
    end

    test "populates status_map from v4 errors.status_map" do
      {:ok, exchange} = Exchange.new("bybit")
      assert is_map(exchange.status_map)
      assert map_size(exchange.status_map) > 0
      # 401 → authentication_error, 500/503 → exchange_not_available
      assert exchange.status_map["401"] == :authentication_error
      assert exchange.status_map["500"] == :exchange_not_available
      assert exchange.status_map["503"] == :exchange_not_available
      assert Enum.all?(exchange.status_map, fn {_k, v} -> is_atom(v) end)
    end

    test "populates retry_classification (class → bucket) from v4 contract" do
      {:ok, exchange} = Exchange.new("bybit")
      assert is_map(exchange.retry_classification)
      assert map_size(exchange.retry_classification) > 0
      # Faithful class-keyed buckets, verbatim from errors.retry_classification.
      assert exchange.retry_classification["AuthenticationError"] == :auth
      assert exchange.retry_classification["RateLimitExceeded"] == :rate_limit
      assert exchange.retry_classification["ExchangeNotAvailable"] == :server_busy
      assert exchange.retry_classification["RequestTimeout"] == :network

      assert Enum.all?(exchange.retry_classification, fn {_k, v} ->
               v in [:auth, :network, :rate_limit, :server_busy, :non_retryable]
             end)
    end

    test "populates error_class_ancestors from v4 class_hierarchy" do
      {:ok, exchange} = Exchange.new("bybit")
      assert is_map(exchange.error_class_ancestors)
      assert map_size(exchange.error_class_ancestors) > 0
      assert is_list(exchange.error_class_ancestors["AuthenticationError"])
    end

    test "resolves unmapped error classes through the hierarchy" do
      {:ok, exchange} = Exchange.new("okx")
      # OKX's exact map can carry codes classified as leaf subclasses; every
      # resolved error type must be a real atom (never a raw string/nil).
      assert Enum.all?(exchange.error_codes, fn {_k, v} -> is_atom(v) and not is_nil(v) end)
    end

    test "every runtime venue resolves authored error classes to atoms" do
      for id <- Spec.exchanges() do
        assert {:ok, exchange} = Exchange.new(id)
        assert Enum.all?(exchange.error_codes, fn {_code, type} -> is_atom(type) and not is_nil(type) end)
      end
    end
  end

  defp authored_exception_codes(exceptions) do
    collect_exception_codes(exceptions, [], nil)
  end

  defp collect_exception_codes(exceptions, path, scope) do
    Enum.flat_map(exceptions, fn
      {"broad", _patterns} ->
        []

      {"exact", entries} when is_map(entries) ->
        exception_code_entries(entries, path ++ ["exact"], scope)

      {key, entries} when is_map(entries) ->
        collect_exception_codes(entries, path ++ [key], scope || key)

      {code, _class} ->
        [{exception_submap(path), scope, code}]
    end)
  end

  defp exception_code_entries(entries, path, scope) do
    Enum.map(entries, fn {code, _class} ->
      {exception_submap(path), scope, code}
    end)
  end

  defp exception_submap([]), do: "flat"
  defp exception_submap(path), do: Enum.join(path, ".")

  defp base_url_entries(map, prefix \\ []) when is_map(map) do
    Enum.flat_map(map, fn
      {section, url} when is_binary(section) and is_binary(url) ->
        [{Enum.join(prefix ++ [section], "."), url}]

      {section, nested} when is_binary(section) and is_map(nested) ->
        base_url_entries(nested, prefix ++ [section])

      _ ->
        []
    end)
  end

  describe "new/2 with credentials" do
    test "builds credentials from api_key and secret" do
      {:ok, exchange} = Exchange.new("bybit", api_key: "abc", secret: "xyz")
      assert exchange.credentials.api_key == "abc"
      assert exchange.credentials.secret == "xyz"
    end

    test "builds credentials with password" do
      {:ok, exchange} = Exchange.new("okx", api_key: "a", secret: "s", password: "p")
      assert exchange.credentials.password == "p"
    end

    test "accepts pre-built credentials struct" do
      {:ok, creds} = Bourse.Credentials.new(api_key: "abc", secret: "xyz")
      {:ok, exchange} = Exchange.new("bybit", credentials: creds)
      assert exchange.credentials.api_key == "abc"
    end

    test "returns error on invalid credentials (missing secret)" do
      assert {:error, :missing_secret} = Exchange.new("bybit", api_key: "abc")
    end

    test "returns error on invalid credentials (missing api_key)" do
      assert {:error, :missing_api_key} = Exchange.new("bybit", secret: "xyz")
    end

    test "returns error on non-struct credentials" do
      assert {:error, {:invalid_credentials, _}} =
               Exchange.new("bybit", credentials: %{api_key: "a", secret: "s"})
    end
  end

  describe "new/2 URL resolution" do
    test "resolves base_urls with hostname interpolation" do
      {:ok, exchange} = Exchange.new("bybit")
      assert is_map(exchange.base_urls)
      assert exchange.base_urls["public"] == "https://api.bybit.com"
      assert exchange.base_urls["private"] == "https://api.bybit.com"
    end

    test "resolves OKX URLs (flat structure)" do
      {:ok, exchange} = Exchange.new("okx")
      assert exchange.base_urls["rest"] == "https://www.okx.com"
    end

    test "sandbox mode uses testnet URLs" do
      {:ok, prod} = Exchange.new("bybit")
      {:ok, sandbox} = Exchange.new("bybit", sandbox: true)
      assert sandbox.sandbox == true
      # Testnet URLs contain "testnet"
      assert String.contains?(sandbox.base_urls["public"], "testnet")
      refute String.contains?(prod.base_urls["public"], "testnet")
    end

    test "sandbox from credentials propagates" do
      {:ok, creds} = Bourse.Credentials.new(api_key: "a", secret: "s", sandbox: true)
      {:ok, exchange} = Exchange.new("bybit", credentials: creds)
      assert exchange.sandbox == true
      assert String.contains?(exchange.base_urls["public"], "testnet")
    end

    test "scalar credential path preserves sandbox on rebuilt Credentials struct" do
      {:ok, exchange} = Exchange.new("bybit", api_key: "a", secret: "s", sandbox: true)
      assert exchange.sandbox == true
      assert exchange.credentials.sandbox == true
    end

    test "explicit sandbox opt overrides credentials" do
      {:ok, creds} = Bourse.Credentials.new(api_key: "a", secret: "s", sandbox: true)
      {:ok, exchange} = Exchange.new("bybit", credentials: creds, sandbox: false)
      assert exchange.sandbox == false
      refute String.contains?(exchange.base_urls["public"], "testnet")
    end

    test "OKX sandbox defaults to the international demo hostname and authored transport headers" do
      {:ok, exchange} = Exchange.new("okx", sandbox: true)

      assert exchange.options["sandboxMode"] == true
      assert exchange.base_urls["rest"] == "https://www.okx.com"
      assert exchange.sandbox_headers == %{"x-simulated-trading" => "1"}
    end

    test "OKX sandbox accepts a hostname override" do
      {:ok, exchange} = Exchange.new("okx", sandbox: true, hostname: "my.okx.com")

      assert exchange.base_urls["rest"] == "https://my.okx.com"
      assert exchange.sandbox_headers == %{"x-simulated-trading" => "1"}
    end
  end

  describe "new/2 options and overrides" do
    test "hostname override" do
      {:ok, exchange} = Exchange.new("bybit", hostname: "custom.bybit.com")
      assert exchange.hostname == "custom.bybit.com"
      assert String.contains?(exchange.base_urls["public"], "custom.bybit.com")
    end

    test "passes options map through" do
      opts_map = %{"recvWindow" => 5000}
      {:ok, exchange} = Exchange.new("bybit", options: opts_map)
      assert exchange.options == opts_map
    end

    test "returns error on unknown option" do
      assert {:error, {:unknown_option, :bogus}} = Exchange.new("bybit", bogus: true)
    end
  end

  describe "new/2 error cases" do
    test "returns a named error for reference-only and unknown exchanges" do
      assert {:error, {:unsupported_exchange, "kraken"}} = Exchange.new("kraken")
      assert {:error, {:unsupported_exchange, "nonexistent_xyz"}} = Exchange.new("nonexistent_xyz")
      assert {:error, {:unsupported_exchange, "../evil"}} = Exchange.new("../evil")
    end
  end

  describe "new!/2" do
    test "returns exchange on success" do
      exchange = Exchange.new!("bybit")
      assert exchange.id == "bybit"
    end

    test "raises on failure" do
      assert_raise ArgumentError, ~r/unsupported exchange: "kraken"/, fn ->
        Exchange.new!("kraken")
      end
    end

    test "raises formatted option and credential errors" do
      assert_raise ArgumentError, ~r/unknown option: :bogus/, fn ->
        Exchange.new!("bybit", bogus: true)
      end

      assert_raise ArgumentError, ~r/secret is required/, fn ->
        Exchange.new!("bybit", api_key: "abc")
      end
    end
  end

  describe "has?/2" do
    test "returns true for supported capability" do
      {:ok, exchange} = Exchange.new("bybit")
      assert Exchange.has?(exchange, "fetchTicker")
    end

    test "returns false for unsupported capability" do
      {:ok, exchange} = Exchange.new("bybit")
      refute Exchange.has?(exchange, "nonexistentCapability")
    end

    test "returns false for capabilities marked false" do
      {:ok, exchange} = Exchange.new("bybit")
      refute Exchange.has?(exchange, "fetchTransactions")
    end

    test "returns true for emulated capabilities from capabilities.has" do
      {:ok, exchange} = Exchange.new("bybit")
      assert exchange.has["fetchFundingRate"] == "emulated"
      assert Exchange.has?(exchange, "fetchFundingRate")
    end
  end

  describe "Bourse.exchange/2 convenience" do
    test "delegates to Exchange.new/2" do
      {:ok, exchange} = Bourse.exchange("bybit")
      assert exchange.id == "bybit"
      assert %Exchange{} = exchange
    end

    test "accepts atom exchange ID" do
      {:ok, exchange} = Bourse.exchange(:bybit)
      assert exchange.id == "bybit"
    end

    test "Bourse.exchange!/2 raises on error" do
      assert_raise ArgumentError, fn ->
        Bourse.exchange!("nonexistent_xyz")
      end
    end

    test "Bourse.exchange!/2 accepts atom" do
      exchange = Bourse.exchange!(:bybit)
      assert exchange.id == "bybit"
    end
  end

  describe "build_exchange_moduledoc/1" do
    test "formats populated metadata and credential requirements" do
      doc =
        Exchange.build_exchange_moduledoc(%{
          exchange_id: "synthetic",
          exchange_name: "Synthetic",
          signing_pattern: :hmac_sha256_query,
          doc_meta: %{
            hostname: "api.synthetic.test",
            version: "v1",
            countries: ["US", "SG"],
            certified: true,
            pro: false,
            required_credentials: %{"apiKey" => true, "secret" => true, "password" => false},
            endpoint_count: 2,
            capability_count: 3,
            sample_capabilities: ["fetchTicker", "fetchBalance"]
          }
        })

      assert doc =~ "- Hostname: `api.synthetic.test`"
      assert doc =~ "- Countries: `US, SG`"
      assert doc =~ "- Certified: `yes`"
      assert doc =~ "- Pro: `no`"
      assert doc =~ "Pattern: `hmac_sha256_query` — HMAC-SHA256 query signing"
      assert doc =~ "Private endpoints require: `apiKey`, `secret`."
      assert doc =~ "Enabled: `fetchTicker`, `fetchBalance` (3 total"
    end

    test "formats sparse metadata without credentials" do
      doc =
        Exchange.build_exchange_moduledoc(%{
          exchange_id: "sparse",
          exchange_name: "Sparse",
          signing_pattern: :unknown_pattern,
          doc_meta: %{
            hostname: nil,
            version: "",
            countries: "MY",
            certified: nil,
            pro: nil,
            required_credentials: %{},
            endpoint_count: 0,
            capability_count: 0,
            sample_capabilities: []
          }
        })

      refute doc =~ "Hostname"
      refute doc =~ "API version"
      assert doc =~ "- Countries: `MY`"
      assert doc =~ "Pattern: `unknown_pattern` — see `Bourse.Signing`"
      assert doc =~ "No credentials required for public endpoints."
      assert doc =~ "0 enabled unified methods"
    end

    test "formats all generated signing pattern descriptions" do
      patterns = [
        {:api_key_secret_headers, "API key and secret header authentication"},
        {:hmac_sha256_query, "HMAC-SHA256 query signing"},
        {:hmac_sha256_headers, "HMAC-SHA256 header signing"},
        {:hmac_sha256_iso_passphrase, "ISO timestamp + passphrase HMAC"},
        {:deribit, "Deribit Authorization header"},
        {:hyperliquid, "EIP-712 / action signing (DEX)"},
        {:derive, "EIP-712 order signing (DEX)"},
        {:lighter, "first-party zk-Schnorr signer"}
      ]

      for {pattern, description} <- patterns do
        assert Exchange.build_exchange_moduledoc(%{
                 exchange_id: "synthetic",
                 exchange_name: "Synthetic",
                 signing_pattern: pattern,
                 doc_meta: %{
                   hostname: nil,
                   version: nil,
                   countries: [],
                   certified: nil,
                   pro: nil,
                   required_credentials: %{},
                   endpoint_count: 0,
                   capability_count: 0,
                   sample_capabilities: []
                 }
               }) =~ description
      end
    end
  end

  describe "markets.currencies catalog (Task 60)" do
    test "populates currencies from spec markets.currencies" do
      {:ok, exchange} = Exchange.new("binance")
      assert is_map(exchange.currencies)
      assert map_size(exchange.currencies) > 0
    end

    test "BTC record carries networks key (empty map on binance — upstream gap)" do
      {:ok, exchange} = Exchange.new("binance")
      assert %{"code" => "BTC", "networks" => networks} = exchange.currencies["BTC"]
      assert networks == %{}
    end

    test "currency/2 returns spec record or nil" do
      {:ok, exchange} = Exchange.new("bybit")
      assert %{"code" => "BTC"} = Exchange.currency(exchange, "BTC")
      assert Exchange.currency(exchange, "NOT_A_CURRENCY") == nil
    end

    test "currency_network/3 returns nil when network absent on empty-network spec" do
      {:ok, exchange} = Exchange.new("binance")
      assert Exchange.currency_network(exchange, "BTC", "ERC20") == nil
    end

    test "populated specs carry network metadata for currency_network/3 (Task 127)" do
      for {exchange_id, _, :populated} <- Helpers.currency_network_rows(),
          {currency_code, network_code, expected} =
            Helpers.currency_network_sample(exchange_id) do
        spec = Spec.load!(exchange_id)
        currencies = spec["markets"]["currencies"]
        assert Map.get(currencies[currency_code]["networks"], network_code) == expected
      end
    end

    test "supported owned specs explicitly carry empty network catalogs" do
      rows = Helpers.currency_network_rows()
      populated = for {id, _, :populated} <- rows, do: id
      empty = for {id, _, :empty} <- rows, do: id

      assert populated == []
      assert Enum.sort(empty) == Spec.exchanges()
    end
  end

  describe "signing_from_spec/1" do
    test "returns no signing path for an explicit public-only venue" do
      spec = %{
        "auth" => %{
          "authenticated_sections" => [],
          "sign_recipe" => %{},
          "signing_config" => %{},
          "signing_pattern" => nil
        }
      }

      assert {nil, %{}} = Exchange.signing_from_spec(spec)
    end
  end
end
