defmodule Bourse.OracleProvenance.DeribitPositionUnits do
  @moduledoc """
  Replays recorded Deribit future positions against their provider-owned unit contract.
  """

  alias Bourse.Exchange
  alias Bourse.JsonDocument
  alias Bourse.Market
  alias Bourse.Safe
  alias Bourse.Unified.DeribitPositionUnits, as: UnitReconciler
  alias Bourse.Unified.ReadParse

  @default_root "test/fixtures/responses"
  @fixture_path "deribit/fetch_positions.json"
  @membership "deribit_position_units"
  @relative_tolerance 1.0e-12

  @doc "Validates recorded inverse and linear position units through the runtime parser."
  @spec validate!(keyword()) :: :ok
  def validate!(opts \\ []) do
    root = opts[:root] || @default_root
    manifest_path = opts[:manifest_path] || Path.join(root, "_manifest.json")
    manifest = JsonDocument.decode_file!(manifest_path)
    recording!(manifest)
    fixture = root |> Path.join(@fixture_path) |> JsonDocument.decode_file!()
    markets = markets!(fixture)

    positions =
      fixture
      |> parse_positions!(markets)
      |> then(Keyword.get(opts, :position_transform, fn positions -> positions end))

    validate_branches!(fixture, markets, positions)
  end

  defp recording!(manifest) do
    recording = Enum.find(manifest["recordings"] || [], &(&1["path"] == @fixture_path))

    ensure!(is_map(recording), "Deribit position-unit recording is not registered")
    ensure!(@membership in (recording["oracle_membership"] || []), "Deribit position-unit oracle membership is missing")
    ensure!(recording["body_populated"] == true, "Deribit position-unit recording is not populated")
    recording
  end

  defp markets!(fixture) do
    markets =
      Enum.map(fixture["market_contexts"] || [], fn %{"normalized" => market, "raw" => raw} ->
        %Market{
          contract_size: Safe.number(market["contract_size"]),
          id: market["id"],
          info: raw,
          inverse: market["inverse"] == true,
          linear: market["linear"] == true,
          symbol: market["symbol"]
        }
      end)

    ensure!(Enum.any?(markets, & &1.inverse), "Deribit position-unit recording has no inverse market context")
    ensure!(Enum.any?(markets, & &1.linear), "Deribit position-unit recording has no linear market context")
    markets
  end

  defp parse_positions!(fixture, markets) do
    exchange = "deribit" |> Exchange.new!() |> Exchange.put_markets(markets)

    with {:ok, positions} <-
           ReadParse.parse(
             exchange,
             Bourse.Deribit,
             :fetch_positions,
             "fetchPositions",
             fixture["body"],
             %{},
             :parse_position,
             true
           ),
         {:ok, reconciled} <- UnitReconciler.reconcile({:ok, positions}, exchange) do
      reconciled
    else
      {:error, reason} -> raise ArgumentError, "Deribit position-unit replay failed: #{inspect(reason)}"
    end
  end

  defp validate_branches!(fixture, markets, positions) do
    rows = get_in(fixture, ["body", "result"])
    ensure!(is_list(rows), "Deribit position-unit recording has no result rows")

    Enum.each(markets, fn market ->
      raw = Enum.find(rows, &(&1["instrument_name"] == market.id and nonzero?(&1["size"])))
      position = Enum.find(positions, &(is_map(&1.info) and &1.info["instrument_name"] == market.id))

      ensure!(is_map(raw), "Deribit position-unit recording has no populated #{market.id} row")
      ensure!(is_struct(position, Bourse.Position), "Deribit position-unit replay dropped #{market.id}")
      validate_position!(position, raw, market)
    end)

    :ok
  end

  defp validate_position!(position, raw, %Market{inverse: true} = market) do
    notional = raw |> Map.fetch!("size") |> Safe.number() |> abs()
    base_quantity = raw |> Map.fetch!("size_currency") |> Safe.number() |> abs()

    assert_number!(market.id, :notional, position.notional, notional)
    assert_number!(market.id, :base_quantity, position.base_quantity, base_quantity)
    assert_number!(market.id, :contracts, position.contracts, notional / market.contract_size)
    assert_side!(market.id, position.side, raw["direction"])
  end

  defp validate_position!(position, raw, %Market{linear: true} = market) do
    notional = raw |> Map.fetch!("size") |> Safe.number() |> abs()
    base_quantity = raw |> Map.fetch!("size_currency") |> Safe.number() |> abs()
    mark_price = raw |> Map.fetch!("mark_price") |> Safe.number()

    assert_number!(market.id, :raw_quote_value, notional, base_quantity * mark_price)
    assert_number!(market.id, :notional, position.notional, notional)
    assert_number!(market.id, :base_quantity, position.base_quantity, base_quantity)
    assert_number!(market.id, :contracts, position.contracts, base_quantity / market.contract_size)
    assert_side!(market.id, position.side, raw["direction"])
  end

  defp assert_number!(instrument, field, actual, expected) when is_number(actual) and is_number(expected) do
    tolerance = max(abs(expected) * @relative_tolerance, @relative_tolerance)

    ensure!(
      abs(actual - expected) <= tolerance,
      "Deribit #{instrument} #{field} expected #{expected}, got #{inspect(actual)}"
    )
  end

  defp assert_number!(instrument, field, actual, expected) do
    raise ArgumentError,
          "Deribit #{instrument} #{field} expected numeric #{inspect(expected)}, got #{inspect(actual)}"
  end

  defp assert_side!(instrument, actual, direction) do
    expected = Map.fetch!(%{"buy" => "long", "sell" => "short"}, direction)
    ensure!(actual == expected, "Deribit #{instrument} side expected #{expected}, got #{inspect(actual)}")
  end

  defp nonzero?(value), do: is_number(Safe.number(value)) and Safe.number(value) != 0

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(ArgumentError, message)
end
