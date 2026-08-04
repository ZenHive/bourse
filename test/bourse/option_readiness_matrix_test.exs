# Task 402 — Standing executable four-venue option readiness matrix.
#
# Mechanical evidence collection across Deribit, OKX, Bybit and Derive.
# Opt-in (excluded by default — offline suite untouched):
#
#     mix test.json --quiet --include option_readiness \
#       test/bourse/option_readiness_matrix_test.exs
#
# Or with the bare tag filter (file-target recommended):
#
#     mix test.json --quiet --only option_readiness \
#       test/bourse/option_readiness_matrix_test.exs
#
# Mutations stay off by default. Pass BOURSE_OPTION_READINESS_MUTATE=1 to
# exercise create/fetch/cancel. Fill attestation is never inferred from a
# lifecycle alone — supply fill evidence via a prior attestation or a future
# mutate+fill path.

defmodule Bourse.OptionReadinessMatrixTest do
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.OptionReadiness
  alias Bourse.OptionReadiness.Cell
  alias Bourse.OptionReadiness.Report
  alias Bourse.OptionReadiness.VenueRow

  @moduletag :option_readiness
  @moduletag :network

  @report_dir "tmp/option_readiness"

  test "collects timestamped evidence for every venue cell and writes a durable report" do
    mutate? = System.get_env("BOURSE_OPTION_READINESS_MUTATE") in ["1", "true", "TRUE"]
    observed_at = System.system_time(:millisecond)

    assert {:ok, %Report{} = report} =
             OptionReadiness.run(
               observed_at: observed_at,
               mutate: mutate?,
               report_dir: @report_dir
             )

    assert length(report.venues) == 4
    assert is_binary(report.path)
    assert File.exists?(report.path)

    if !mutate? do
      refute OptionReadiness.accept_baseline?(report)
      assert Enum.any?(OptionReadiness.baseline_rejection_reasons(report), &(&1 =~ "create_fetch_cancel"))
    end

    for row <- report.venues do
      assert row.venue in OptionReadiness.venues()
      assert is_binary(row.environment)
      assert is_integer(row.observed_at)

      for name <- OptionReadiness.cells() do
        assert %Cell{name: ^name, observed_at: cell_at, environment: env, outcome: outcome} =
                 Map.fetch!(row.cells, name)

        assert is_integer(cell_at)
        assert is_binary(env)

        # Lifecycle stays untested unless mutate is enabled — that is intentional
        # and must not be silently upgraded into fill evidence.
        if name == :create_fetch_cancel and not mutate? do
          assert outcome == :untested
        end
      end

      # Empty books must surface as market_unavailable, never fill_ready.
      if row.book && (row.book[:empty] || row.book["empty"]) do
        assert row.status == :market_unavailable
      end

      if row.status == :fill_ready do
        assert VenueRow.fill_ready_evidence?(row)
      end

      # Orthogonal short capability is always present; green only with validated evidence.
      assert is_map(row.capabilities)
      assert is_boolean(row.capabilities.short_fill_ready)
      assert row.side_status.short in [:short_fill_ready, :not_ready]

      if row.capabilities.short_fill_ready do
        assert VenueRow.short_fill_ready_evidence?(row)
        assert row.side_status.short == :short_fill_ready
      else
        refute VenueRow.short_fill_ready_evidence?(row)
        assert row.side_status.short == :not_ready
      end
    end

    encoded = Jason.decode!(File.read!(report.path))
    assert encoded["schema_version"] == 1
    assert encoded["path"] == report.path
    assert length(encoded["venues"]) == 4

    for venue <- encoded["venues"] do
      cell_names = venue["cells"] |> Map.keys() |> Enum.sort()
      assert cell_names == OptionReadiness.cells() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
      assert is_map(venue["capabilities"])
      assert is_boolean(venue["capabilities"]["short_fill_ready"])
      assert venue["side_status"]["short"] in ["short_fill_ready", "not_ready"]
    end
  end

  test "missing credentials for a single venue fail with exact setup instructions" do
    vars = ["BYBIT_DEMO_API_KEY", "BYBIT_DEMO_API_SECRET"]
    previous = Map.new(vars, &{&1, System.get_env(&1)})
    Enum.each(vars, &System.delete_env/1)

    try do
      assert {:error, %Error{type: :authentication_error, message: message}} =
               OptionReadiness.collect_venue("bybit")

      assert message =~ ~s(export BYBIT_DEMO_API_KEY="your_demo_api_key")
      assert message =~ ~s(export BYBIT_DEMO_API_SECRET="your_demo_api_secret")
      assert message =~ "api-demo.bybit.com"
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
