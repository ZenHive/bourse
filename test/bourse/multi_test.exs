defmodule Bourse.MultiTest do
  @moduledoc "Tests for Bourse.Multi — parallel multi-exchange fetch with partial-failure handling."

  # async: false — Req.Test.stub uses global (per-owner) state shared with the
  # Task.async_stream child processes via $callers propagation.
  use ExUnit.Case, async: false

  alias Bourse.Exchange
  alias Bourse.Multi
  alias Bourse.Test.RequestCollector
  alias Bourse.TestExchange.Bybit

  doctest Multi

  @moduletag capture_log: true

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_stub do
    :"multi_stub_#{System.unique_integer([:positive])}"
  end

  # Builds a minimal public-only exchange backed by the Bybit test module.
  # `id` distinguishes structs so they remain distinct result-map keys.
  defp build_exchange(id) do
    %Exchange{
      id: id,
      name: id,
      credentials: nil,
      sandbox: false,
      rate_limit_ms: 0,
      hostname: nil,
      base_urls: %{"public" => "https://api.bybit.com", "private" => "https://api.bybit.com"},
      has: Bybit.__features__(),
      required_credentials: %{},
      signing_pattern: :hmac_sha256_headers,
      signing_config: Bybit.__signing__().config,
      options: %{},
      error_codes: %{},
      broad_error_patterns: %{},
      http_exceptions: %{},
      module: Bybit,
      spec: %{}
    }
  end

  defp stub_json(stub, body) do
    Req.Test.stub(stub, fn conn -> Req.Test.json(conn, body) end)
  end

  # ---------------------------------------------------------------------------
  # parallel_call — list form
  # ---------------------------------------------------------------------------

  describe "parallel_call/4 (list form)" do
    test "calls the unified function across all exchanges and keys by struct" do
      stub = unique_stub()
      stub_json(stub, %{"lastPrice" => "67000"})

      a = build_exchange("ex_a")
      b = build_exchange("ex_b")

      result = Multi.parallel_call([a, b], :fetch_ticker, ["BTC/USDT", [plug: {Req.Test, stub}]])

      assert map_size(result) == 2
      assert {:ok, resp_a} = result[a]
      assert {:ok, _resp_b} = result[b]
      assert %Bourse.Ticker{last: 67_000.0} = resp_a
    end

    test "empty list returns empty map" do
      assert Multi.parallel_call([], :fetch_ticker, ["BTC/USDT"]) == %{}
    end

    test "unexported function yields a {:function_not_exported, _} error per exchange" do
      a = build_exchange("ex_a")

      result = Multi.parallel_call([a], :totally_not_a_method, [])

      assert {:error, {:function_not_exported, {Bourse, :totally_not_a_method, 1}}} = result[a]
    end

    test "a non-exchange element yields a {:not_an_exchange, _} error" do
      result = Multi.parallel_call([:nope], :fetch_ticker, ["BTC/USDT"])

      assert result[:nope] == {:error, {:not_an_exchange, :nope}}
    end

    test "per-exchange timeout produces {:error, :timeout} without killing siblings" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        # Sleep well past the configured per-exchange timeout.
        Process.sleep(300)
        Req.Test.json(conn, %{"retCode" => 0})
      end)

      a = build_exchange("ex_a")

      result = Multi.parallel_call([a], :fetch_ticker, ["BTC/USDT", [plug: {Req.Test, stub}]], timeout: 50)

      assert result[a] == {:error, :timeout}
    end
  end

  # ---------------------------------------------------------------------------
  # parallel_call — map form (per-exchange first arg)
  # ---------------------------------------------------------------------------

  describe "parallel_call/4 (map form)" do
    test "prepends the per-exchange value as the first call argument" do
      stub = unique_stub()

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{"retCode" => 0, "lastPrice" => "67000", "echo_query" => conn.query_string})
      end)

      a = build_exchange("ex_a")
      b = build_exchange("ex_b")

      # Each exchange gets its own symbol; opts are shared trailing args.
      result =
        Multi.parallel_call(
          %{a => "BTC/USDT", b => "ETH/USDT"},
          :fetch_ticker,
          [[plug: {Req.Test, stub}]]
        )

      assert {:ok, _} = result[a]
      assert {:ok, _} = result[b]
    end

    test "empty map returns empty map" do
      assert Multi.parallel_call(%{}, :fetch_ticker, []) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # fetch_tickers
  # ---------------------------------------------------------------------------

  describe "fetch_tickers/2,3" do
    test "list form fetches a shared symbol across exchanges" do
      stub = unique_stub()
      stub_json(stub, %{"retCode" => 0, "lastPrice" => "67000"})

      a = build_exchange("ex_a")
      b = build_exchange("ex_b")

      result = Multi.fetch_tickers([a, b], "BTC/USDT", plug: {Req.Test, stub})

      assert {:ok, _} = result[a]
      assert {:ok, _} = result[b]
    end

    test "map form fetches per-exchange symbols" do
      stub = unique_stub()
      stub_json(stub, %{"retCode" => 0, "lastPrice" => "67000"})

      a = build_exchange("ex_a")

      result = Multi.fetch_tickers(%{a => "BTC/USDT"}, plug: {Req.Test, stub})

      assert {:ok, _} = result[a]
    end
  end

  # ---------------------------------------------------------------------------
  # fetch_order_books
  # ---------------------------------------------------------------------------

  describe "fetch_order_books/2,3" do
    test "list form forwards :limit to the underlying call" do
      stub = unique_stub()
      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"retCode" => 0, "result" => %{}})
      end)

      a = build_exchange("ex_a")

      result = Multi.fetch_order_books([a], "BTC/USDT", limit: 5, plug: {Req.Test, stub})

      assert {:ok, _} = result[a]

      params = RequestCollector.query(requests)
      assert params["limit"] == "5"
    end

    test "map form fetches per-exchange symbols" do
      stub = unique_stub()
      stub_json(stub, %{"retCode" => 0, "result" => %{}})

      a = build_exchange("ex_a")

      result = Multi.fetch_order_books(%{a => "BTC/USDT"}, plug: {Req.Test, stub})

      assert {:ok, _} = result[a]
    end
  end

  # ---------------------------------------------------------------------------
  # Result helpers
  # ---------------------------------------------------------------------------

  describe "successes/1 and failures/1" do
    test "partition a mixed result map and unwrap the values" do
      a = build_exchange("ex_a")
      b = build_exchange("ex_b")
      results = %{a => {:ok, %{price: 100}}, b => {:error, :timeout}}

      assert Multi.successes(results) == %{a => %{price: 100}}
      assert Multi.failures(results) == %{b => :timeout}
    end

    test "successes is empty when everything failed" do
      a = build_exchange("ex_a")
      results = %{a => {:error, :boom}}

      assert Multi.successes(results) == %{}
      assert Multi.failures(results) == %{a => :boom}
    end
  end
end
