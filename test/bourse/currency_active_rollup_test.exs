defmodule Bourse.CurrencyActiveRollupTest do
  @moduledoc """
  Task 482 — first-class currency `active` rollup is an authored decision, never a
  silent default.

  Every first-class venue that derives `active` from per-chain deposit/withdraw
  flags must declare `active_requires_both` (boolean) on that rule. Long-tail may
  omit the key and inherit OR; first-class may not.
  """

  use ExUnit.Case, async: true

  alias Bourse.ResponseParser
  alias Bourse.Unified

  @first_class_venues ~w(alpaca binance binancecoinm binanceusdm bybit coinbaseexchange deribit derive hyperliquid lighter okx)

  for exchange_id <- @first_class_venues do
    @external_resource Path.expand(
                         "../../priv/venues/#{exchange_id}/authored/spec.json",
                         __DIR__
                       )
  end

  test "first-class chain-derived active rules declare active_requires_both" do
    assert @first_class_venues == Unified.first_class_venues()

    errors = Enum.flat_map(@first_class_venues, &venue_active_rollup_errors/1)

    assert errors == [], """
    First-class currency maps that roll `active` from chain deposit/withdraw flags
    must set `active_requires_both` to true or false (task 482). Found:

    #{Enum.map_join(errors, "\n", &("  - " <> &1))}
    """
  end

  test "declared active_requires_both choices match the confronted venue contract" do
    # Option (b): split is deliberate and explicit — binance/okx AND, bybit OR.
    # C-T442a/f + C-T482a/b; C-T442b + C-T482c.
    assert venue_active_flags("binance") == %{networks: true}
    assert venue_active_flags("okx") == %{active: true, networks: true}
    assert venue_active_flags("bybit") == %{active: false, networks: false}
  end

  test "active_requires_both false keeps one-sided chains active (OR)" do
    rules = %{
      "active" => %{
        "kind" => "currency_network_summary",
        "collection_key" => "chains",
        "field" => "active",
        "active_requires_both" => false
      },
      "networks" => %{
        "kind" => "currency_networks",
        "collection_key" => "chains",
        "active_requires_both" => false
      }
    }

    data = %{
      "coin" => "USDT",
      "chains" => [
        %{"chain" => "ETH", "chainDeposit" => "1", "chainWithdraw" => "0"}
      ]
    }

    assert {:ok, %Bourse.Currency{} = currency} =
             ResponseParser.apply_mappings(data, rules, target: Bourse.Currency)

    assert currency.active
    assert currency.networks["ETH"]["active"]
    assert currency.networks["ETH"]["deposit"]
    refute currency.networks["ETH"]["withdraw"]
  end

  test "active_requires_both true requires both directions (AND)" do
    rules = %{
      "active" => %{
        "kind" => "currency_network_summary",
        "collection_key" => "chains",
        "field" => "active",
        "deposit_key" => "canDep",
        "withdraw_key" => "canWd",
        "active_requires_both" => true
      },
      "networks" => %{
        "kind" => "currency_networks",
        "collection_key" => "chains",
        "currency_key" => "ccy",
        "network_key" => "chain",
        "deposit_key" => "canDep",
        "withdraw_key" => "canWd",
        "active_requires_both" => true
      }
    }

    one_sided = %{
      "ccy" => "BTC",
      "chains" => [%{"chain" => "BTC-Bitcoin", "canDep" => true, "canWd" => false}]
    }

    both = %{
      "ccy" => "BTC",
      "chains" => [%{"chain" => "BTC-Bitcoin", "canDep" => true, "canWd" => true}]
    }

    assert {:ok, %Bourse.Currency{} = inactive} =
             ResponseParser.apply_mappings(one_sided, rules, target: Bourse.Currency)

    refute inactive.active
    refute inactive.networks["BTC-Bitcoin"]["active"]
    assert inactive.networks["BTC-Bitcoin"]["deposit"]
    refute inactive.networks["BTC-Bitcoin"]["withdraw"]

    assert {:ok, %Bourse.Currency{} = active} =
             ResponseParser.apply_mappings(both, rules, target: Bourse.Currency)

    assert active.active
    assert active.networks["BTC-Bitcoin"]["active"]
  end

  defp venue_active_rollup_errors(exchange_id) do
    exchange_id
    |> currency_field_map()
    |> active_rollup_rules()
    |> Enum.flat_map(fn {path, rule} ->
      case Map.fetch(rule, "active_requires_both") do
        {:ok, flag} when is_boolean(flag) ->
          []

        {:ok, other} ->
          [
            "#{exchange_id} #{path}: active_requires_both must be a boolean, got #{inspect(other)}"
          ]

        :error ->
          [
            "#{exchange_id} #{path}: missing active_requires_both (first-class must declare true or false)"
          ]
      end
    end)
  end

  defp venue_active_flags(exchange_id) do
    exchange_id
    |> currency_field_map()
    |> active_rollup_rules()
    |> Map.new(fn {path, rule} ->
      key =
        case path do
          "field_map.active" -> :active
          "field_map.networks" -> :networks
        end

      {key, Map.fetch!(rule, "active_requires_both")}
    end)
  end

  defp currency_field_map(exchange_id) do
    exchange_id
    |> Bourse.Spec.authored_spec_path()
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["normalization", "field_maps", "currency", "field_map"])
  end

  defp active_rollup_rules(nil), do: []

  defp active_rollup_rules(field_map) when is_map(field_map) do
    Enum.flat_map(field_map, fn {key, rule} ->
      if active_rollup_rule?(rule) do
        [{"field_map.#{key}", rule}]
      else
        []
      end
    end)
  end

  defp active_rollup_rule?(%{"kind" => "currency_networks"}), do: true

  defp active_rollup_rule?(%{"kind" => "currency_network_summary", "field" => "active"}), do: true

  defp active_rollup_rule?(_), do: false
end
