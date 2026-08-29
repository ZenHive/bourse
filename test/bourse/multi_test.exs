defmodule Bourse.MultiTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Multi

  test "empty specialized calls preserve the empty result" do
    assert Multi.fetch_tickers([], "BTC/USDT") == %{}
    assert Multi.fetch_tickers(%{}) == %{}
    assert Multi.fetch_tickers(%{}, timeout: 1, limit: 5) == %{}
    assert Multi.fetch_order_books([], "BTC/USDT", timeout: 1, limit: 5) == %{}
    assert Multi.fetch_order_books(%{}) == %{}
    assert Multi.fetch_order_books(%{}, timeout: 1) == %{}
  end

  test "list calls keep partial failures keyed by exchange" do
    first = %Exchange{id: "first", name: "first"}
    second = %Exchange{id: "second", name: "second"}

    results = Multi.parallel_call([first, second], :not_exported, [], timeout: 100)
    assert results[first] == {:error, {:function_not_exported, {Bourse, :not_exported, 1}}}
    assert results[second] == {:error, {:function_not_exported, {Bourse, :not_exported, 1}}}
    assert Multi.successes(results) == %{}

    assert Multi.failures(results) == %{
             first => {:function_not_exported, {Bourse, :not_exported, 1}},
             second => {:function_not_exported, {Bourse, :not_exported, 1}}
           }
  end

  test "map calls prepend each exchange-specific argument" do
    exchange = %Exchange{id: "fixture", name: "fixture"}
    results = Multi.parallel_call(%{exchange => "BTC/USDT"}, :not_exported, [:shared], timeout: 100)
    assert results[exchange] == {:error, {:function_not_exported, {Bourse, :not_exported, 3}}}
  end

  test "non-exchange inputs are normalized and helper filters unwrap values" do
    assert %{bad: {:error, {:not_an_exchange, :bad}}} = Multi.parallel_call([:bad], :anything, [])

    results = %{a: {:ok, 1}, b: {:error, :timeout}, c: {:ok, 3}}
    assert Multi.successes(results) == %{a: 1, c: 3}
    assert Multi.failures(results) == %{b: :timeout}
  end

  test "exported calls convert raised exceptions into explicit failures" do
    exchange = %Exchange{id: "fixture", name: "fixture"}
    assert %{^exchange => {:error, {:exception, message}}} = Multi.parallel_call([exchange], :exchange, [])
    assert is_binary(message)
  end
end
