defmodule Bourse.WS.ConfigTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Config

  test "supported_exchanges/0 returns every configured exchange id" do
    exchanges = Config.supported_exchanges()

    assert "bybit" in exchanges
    assert "deribit" in exchanges
    assert "okx" in exchanges
    assert "hyperliquid" in exchanges
    assert "binanceusdm" in exchanges
    assert "derive" in exchanges
    assert Enum.all?(exchanges, &Config.supported?/1)
  end
end
