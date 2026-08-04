defmodule Bourse.Unified.ReadParseSlotsTest do
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.Exchange

  describe "live read-parse probes — funding_rate, greeks, option_chain" do
    @moduletag :network

    test "bybit fetch_funding_rates returns %FundingRate{} dict" do
      exchange = Exchange.new!("bybit")

      case Bourse.fetch_funding_rates(exchange, %{"category" => "linear", "symbol" => "BTC/USDT:USDT"}) do
        {:ok, rates} when is_map(rates) ->
          assert map_size(rates) > 0
          assert Enum.all?(rates, fn {_sym, fr} -> match?(%Bourse.FundingRate{}, fr) end)

        {:error, %Error{type: type} = err} ->
          flunk("bybit fetch_funding_rates failed (#{type}): #{Exception.message(err)}")
      end
    end

    test "bybit emulated fetch_funding_rate resolves via carved market index credential-free" do
      exchange = Exchange.new!("bybit")

      case Bourse.fetch_funding_rate(exchange, "BTC/USDT:USDT") do
        {:ok, %Bourse.FundingRate{} = fr} ->
          assert fr.symbol == "BTC/USDT:USDT" or is_nil(fr.symbol)
          assert is_number(fr.funding_rate) or is_nil(fr.funding_rate)

        {:error, %Error{type: :invalid_parameters, message: message}} ->
          flunk("bybit fetch_funding_rate symbol resolution failed: #{message}")

        {:error, %Error{type: type} = err} ->
          flunk("bybit fetch_funding_rate failed (#{type}): #{Exception.message(err)}")
      end
    end

    test "hyperliquid emulated fetch_ticker resolves via carved market index credential-free" do
      exchange = Exchange.new!("hyperliquid")

      case Bourse.fetch_ticker(exchange, "BTC/USDC:USDC") do
        {:ok, %Bourse.Ticker{} = ticker} ->
          assert ticker.symbol == "BTC/USDC:USDC"
          assert is_number(ticker.last)

        {:error, %Error{type: :exchange_error, message: message}} ->
          flunk("hyperliquid fetch_ticker symbol resolution failed: #{message}")

        {:error, %Error{type: type} = err} ->
          flunk("hyperliquid fetch_ticker failed (#{type}): #{Exception.message(err)}")
      end
    end

    test "hyperliquid fetch_ticker returns exchange_error for unknown symbol" do
      exchange = Exchange.new!("hyperliquid")

      assert {:error, %Error{type: :exchange_error, message: message}} =
               Bourse.fetch_ticker(exchange, "ZZZZZ/NOPE:USDC")

      assert String.contains?(message, "could not find a ticker for")
    end

    test "lighter fetch_ticker resolves market_id and returns %Ticker{} (T197)" do
      exchange = Exchange.new!("lighter")

      refute Bourse.Emulation.emulated?(exchange, :fetch_ticker, :rest)

      case Bourse.fetch_ticker(exchange, "BTC/USDC:USDC") do
        {:ok, %Bourse.Ticker{} = ticker} ->
          assert ticker.symbol == "BTC/USDC:USDC"
          # lighter ticker field map authors last as safeString; accept number or non-empty string
          refute ticker.last in [nil, ""]

        {:error, %Error{type: :exchange_not_available, http_status: 400} = err} ->
          flunk(
            "lighter still sending invalid market_id param (#{Exception.message(err)}) — " <>
              "request shape must use numeric market_id from markets"
          )

        {:error, %Error{type: type} = err} ->
          flunk("lighter fetch_ticker unexpected failure (#{type}): #{Exception.message(err)}")
      end
    end

    test "lighter fetch_ticker returns bad_symbol for unknown market (T197)" do
      exchange = Exchange.new!("lighter")

      assert {:error, %Error{type: :bad_symbol, message: message}} =
               Bourse.fetch_ticker(exchange, "ZZZZZ/NOPE:USDC")

      assert String.contains?(message, "Unknown market symbol")
    end

    test "deribit fetch_funding_rate returns %FundingRate{}" do
      exchange = Exchange.new!("deribit")

      case Bourse.fetch_funding_rate(exchange, "BTC-PERPETUAL") do
        {:ok, %Bourse.FundingRate{} = fr} ->
          assert is_number(fr.funding_rate) or is_nil(fr.funding_rate)

        {:error, %Error{type: type} = err} ->
          flunk("deribit fetch_funding_rate failed (#{type}): #{Exception.message(err)}")
      end
    end

    test "bybit fetch_greeks returns %Greeks{}" do
      exchange = Exchange.new!("bybit")

      with {:ok, chain} <- Bourse.fetch_option_chain(exchange, "BTC"),
           {symbol, _} <- Enum.find(chain, fn {_sym, _opt} -> true end) do
        case Bourse.fetch_greeks(exchange, symbol) do
          {:ok, %Bourse.Greeks{} = greeks} ->
            assert is_binary(greeks.symbol) or is_nil(greeks.symbol)

          {:error, %Error{type: type} = err} ->
            flunk("bybit fetch_greeks failed (#{type}): #{Exception.message(err)}")
        end
      else
        {:error, %Error{type: type} = err} ->
          flunk("bybit fetch_option_chain failed (#{type}): #{Exception.message(err)}")

        nil ->
          flunk("bybit fetch_option_chain returned no symbols to probe fetch_greeks")
      end
    end

    test "deribit fetch_greeks returns %Greeks{}" do
      exchange = Exchange.new!("deribit")

      with {:ok, chain} <- Bourse.fetch_option_chain(exchange, "BTC"),
           {symbol, _} <- Enum.find(chain, fn {_sym, _opt} -> true end) do
        case Bourse.fetch_greeks(exchange, symbol) do
          {:ok, %Bourse.Greeks{} = greeks} ->
            assert is_number(greeks.delta) or is_nil(greeks.delta)

          {:error, %Error{type: type} = err} ->
            flunk("deribit fetch_greeks failed (#{type}): #{Exception.message(err)}")
        end
      else
        {:error, %Error{type: type} = err} ->
          flunk("deribit fetch_option_chain failed (#{type}): #{Exception.message(err)}")

        nil ->
          flunk("deribit fetch_option_chain returned no symbols to probe fetch_greeks")
      end
    end

    test "bybit fetch_option_chain returns %OptionData{} values" do
      exchange = Exchange.new!("bybit")

      case Bourse.fetch_option_chain(exchange, "BTC") do
        {:ok, chain} when is_map(chain) ->
          assert map_size(chain) > 0
          assert Enum.all?(chain, fn {_sym, opt} -> match?(%Bourse.OptionData{}, opt) end)

        {:error, %Error{type: type} = err} ->
          flunk("bybit fetch_option_chain failed (#{type}): #{Exception.message(err)}")
      end
    end

    test "deribit fetch_option_chain returns %OptionData{} values" do
      exchange = Exchange.new!("deribit")

      case Bourse.fetch_option_chain(exchange, "BTC") do
        {:ok, chain} when is_map(chain) ->
          assert map_size(chain) > 0
          assert Enum.all?(chain, fn {_sym, opt} -> match?(%Bourse.OptionData{}, opt) end)

        {:error, %Error{type: type} = err} ->
          flunk("deribit fetch_option_chain failed (#{type}): #{Exception.message(err)}")
      end
    end
  end
end
