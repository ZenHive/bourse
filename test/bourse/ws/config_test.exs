defmodule Bourse.WS.ConfigTest do
  use ExUnit.Case, async: true

  alias Bourse.Spec
  alias Bourse.WS.Config

  test "configured exchanges plus registered divergences equal runtime support" do
    configured = Config.supported_exchanges()
    divergences = Config.registered_divergences()

    assert divergences == %{"coinbaseexchange" => :websocket_not_configured}
    assert Enum.sort(configured ++ Map.keys(divergences)) == Spec.exchanges()
    assert Enum.all?(configured, &Config.supported?/1)
    refute Enum.any?(Map.keys(divergences), &Config.supported?/1)
  end

  test "alpaca and lighter expose provider-authored public transport config" do
    alpaca = Config.for_exchange("alpaca")
    lighter = Config.for_exchange("lighter")

    assert alpaca.public_url_sandbox == "wss://stream.data.alpaca.markets/v2/test"
    assert alpaca.subscription_pattern == :action_channels
    assert alpaca.auth_pattern == :action_key_secret
    assert alpaca.auth_sections == [:public]

    assert lighter.public_url_sandbox == "wss://testnet.zklighter.elliot.ai/stream"
    assert lighter.subscription_pattern == :type_subscribe
    assert lighter.subscription_config == %{args_field: "channel", args_format: :string}
    assert lighter.auth_pattern == nil
  end

  test "missing config distinguishes a runtime venue from an unknown id" do
    assert Config.missing_config_error("coinbaseexchange") == {:error, :websocket_not_configured}
    assert Config.missing_config_error("kraken") == {:error, :unsupported_exchange}
  end
end
