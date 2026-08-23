defmodule Bourse.MaintenanceErrorClassificationTest do
  @moduledoc """
  Pins provider-documented maintenance codes to OnMaintenance → :exchange_not_available.

  Task 490: after task 461 dropped non-authoritative message sentinels, code-based
  maintenance classification must remain reachable from each venue's own enumeration.
  """

  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.HTTP.Errors
  alias Mix.Tasks.Ccxt.AuthorityCorpus

  # Documented identifiers from priv/venues/<venue>/authority/errors.json (maintenance_adjudication).
  # Runtime type is :exchange_not_available (from_spec_class("OnMaintenance")).
  @mapped_venues [
    {"binance", "-1016", "code"},
    {"binanceusdm", "-1016", "code"},
    {"bybit", "180023", "retCode"},
    {"okx", "50001", "code"},
    {"deribit", "11051", "code"}
  ]

  @no_documented_maintenance ~w(derive hyperliquid)

  test "OnMaintenance class resolves to :exchange_not_available" do
    assert Error.from_spec_class("OnMaintenance") == :exchange_not_available
    assert Error.retry_class(:exchange_not_available) == :server_busy
  end

  for {venue, identifier, _field} <- @mapped_venues do
    @venue venue
    @identifier identifier

    test "#{venue} maps documented maintenance identifier #{identifier} to :exchange_not_available" do
      exchange = Exchange.new!(@venue)
      assert exchange.error_codes[@identifier] == :exchange_not_available
    end
  end

  test "classify_response routes each documented maintenance code through the body path" do
    for {venue, identifier, field} <- @mapped_venues do
      exchange = Exchange.new!(venue)
      body = maintenance_body(venue, field, identifier)

      assert {:error, %Error{type: :exchange_not_available, code: code}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)

      assert to_string(code) == identifier
    end
  end

  test "venues without a documented maintenance code record that finding in the authority corpus" do
    for venue <- @no_documented_maintenance do
      corpus =
        ["priv", "venues", venue, "authority", "errors.json"]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!()

      adjudication = corpus["maintenance_adjudication"]
      assert adjudication["status"] == "no_documented_maintenance_code"
      assert adjudication["identifiers"] == []
      assert is_binary(adjudication["finding"]) and adjudication["finding"] != ""
    end
  end

  test "authority corpus records a maintenance adjudication for every first-class venue" do
    # Enumeration-exempt venues ship no errors.json by contract (task 451).
    venues = AuthorityCorpus.error_enumeration_venues()

    for venue <- venues do
      corpus =
        ["priv", "venues", venue, "authority", "errors.json"]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!()

      adjudication = corpus["maintenance_adjudication"]
      assert is_map(adjudication), "#{venue} missing maintenance_adjudication"
      assert adjudication["ccxt_class"] == "OnMaintenance"
      assert adjudication["ccxt_type"] == "exchange_not_available"
      assert adjudication["adjudicated_at"] =~ ~r/^\d{4}-\d{2}-\d{2}$/
      assert adjudication["status"] in ~w(mapped confirmed_mapped no_documented_maintenance_code)
    end
  end

  defp maintenance_body("bybit", "retCode", identifier) do
    %{"retCode" => String.to_integer(identifier), "retMsg" => "Service maintenance", "result" => %{}}
  end

  defp maintenance_body("deribit", "code", identifier) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{"code" => String.to_integer(identifier), "message" => "system_maintenance"}
    }
  end

  defp maintenance_body(_venue, field, identifier) do
    code = if String.starts_with?(identifier, "-"), do: String.to_integer(identifier), else: identifier
    %{field => code, "msg" => "maintenance"}
  end
end
