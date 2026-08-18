defmodule Bourse.WS.SubscriptionTest do
  use ExUnit.Case, async: true

  alias Bourse.WS.Subscription

  @all_patterns [
    :action_channels,
    :op_subscribe,
    :op_subscribe_objects,
    :method_subscribe,
    :method_params_subscribe,
    :method_subscription,
    :jsonrpc_subscribe,
    :event_subscribe,
    :type_subscribe,
    :sub_subscribe,
    :custom
  ]

  describe "patterns/0" do
    test "lists exactly the 11 supported atoms" do
      assert Enum.sort(Subscription.patterns()) == Enum.sort(@all_patterns)
    end
  end

  describe "module_for_pattern/1" do
    test "maps every listed pattern to a defined module" do
      for pattern <- Subscription.patterns() do
        module = Subscription.module_for_pattern(pattern)
        refute is_nil(module), "no module for #{pattern}"
        assert Code.ensure_loaded?(module), "module #{inspect(module)} not compiled"
      end
    end

    test "returns nil for unknown patterns" do
      assert Subscription.module_for_pattern(:nonexistent) == nil
    end

    test "returns nil for pruned / unregistered pattern atoms" do
      for pattern <- [:method_topics, :method_as_topic, :reqtype_sub, :action_subscribe, :method_params] do
        assert Subscription.module_for_pattern(pattern) == nil
      end
    end
  end

  describe "build_subscribe/3" do
    test "dispatches to the pattern module for a known pattern" do
      assert {:ok, %{"op" => "subscribe", "args" => ["x"]}} =
               Subscription.build_subscribe(:op_subscribe, ["x"], %{})
    end

    test "returns {:error, {:unknown_pattern, _}} for unknown patterns" do
      assert {:error, {:unknown_pattern, :not_a_pattern}} =
               Subscription.build_subscribe(:not_a_pattern, [], %{})
    end
  end

  describe "build_unsubscribe/3" do
    test "dispatches to the pattern module for a known pattern" do
      assert {:ok, %{"op" => "unsubscribe", "args" => ["x"]}} =
               Subscription.build_unsubscribe(:op_subscribe, ["x"], %{})
    end

    test "returns {:error, {:unknown_pattern, _}} for unknown patterns" do
      assert {:error, {:unknown_pattern, :not_a_pattern}} =
               Subscription.build_unsubscribe(:not_a_pattern, [], %{})
    end
  end

  # Regression for the dispatcher pass-through fix: pattern modules now
  # return `{:error, term()}` for input-shape rejections (T98/T99 dual-shape
  # contract). The dispatcher must NOT wrap those in `{:ok, _}` — that
  # would let the bad tuple reach `Bourse.WS.send_payload/2` and crash with
  # FunctionClauseError.
  describe "pattern-module {:error, _} returns propagate verbatim" do
    test "build_subscribe/3 surfaces :multiple_maps_not_supported from :event_subscribe" do
      assert {:error, :multiple_maps_not_supported} =
               Subscription.build_subscribe(
                 :event_subscribe,
                 [%{"channel" => "ticker", "symbol" => "tBTCUSD"}, %{"channel" => "book", "symbol" => "tETHUSD"}],
                 %{}
               )
    end

    test "build_subscribe/3 surfaces :mixed_channel_types from :event_subscribe" do
      assert {:error, :mixed_channel_types} =
               Subscription.build_subscribe(
                 :event_subscribe,
                 ["str", %{"channel" => "ticker", "symbol" => "tBTCUSD"}],
                 %{}
               )
    end

    test "build_subscribe/3 surfaces :multiple_maps_not_supported from :method_params_subscribe" do
      assert {:error, :multiple_maps_not_supported} =
               Subscription.build_subscribe(
                 :method_params_subscribe,
                 [%{"channel" => "ticker", "symbol" => ["BTC/USD"]}, %{"channel" => "book", "symbol" => ["ETH/USD"]}],
                 %{}
               )
    end

    test "build_subscribe/3 surfaces :mixed_channel_types from :method_params_subscribe" do
      assert {:error, :mixed_channel_types} =
               Subscription.build_subscribe(
                 :method_params_subscribe,
                 ["ticker", %{"channel" => "book", "symbol" => ["ETH/USD"]}],
                 %{}
               )
    end

    test "build_unsubscribe/3 mirrors the error pass-through for :event_subscribe" do
      assert {:error, :multiple_maps_not_supported} =
               Subscription.build_unsubscribe(
                 :event_subscribe,
                 [%{"channel" => "ticker"}, %{"channel" => "book"}],
                 %{}
               )
    end

    test "build_unsubscribe/3 mirrors the error pass-through for :method_params_subscribe" do
      assert {:error, :mixed_channel_types} =
               Subscription.build_unsubscribe(
                 :method_params_subscribe,
                 ["ticker", %{"channel" => "book"}],
                 %{}
               )
    end
  end

  describe "every pattern module builds subscribe/unsubscribe without raising" do
    test "with a representative channel list" do
      for pattern <- Subscription.patterns() do
        channels = channels_for(pattern)
        config = config_for(pattern)
        assert {:ok, sub} = Subscription.build_subscribe(pattern, channels, config)
        assert {:ok, unsub} = Subscription.build_unsubscribe(pattern, channels, config)
        assert is_map(sub) or is_list(sub), "pattern #{pattern} returned neither map nor list"
        assert is_map(unsub) or is_list(unsub), "pattern #{pattern} (unsub) returned neither map nor list"
      end
    end
  end

  # Some patterns require minimal config to be well-formed.
  defp channels_for(:action_channels), do: ["trades:BTCUSDT"]
  defp channels_for(_pattern), do: ["tickers.BTCUSDT"]

  defp config_for(:op_subscribe_objects), do: %{}
  defp config_for(:custom), do: %{custom_type: "sendTopicAction"}
  defp config_for(_), do: %{}
end
