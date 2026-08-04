defmodule Bourse.OptionReadinessTest do
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.OptionReadiness
  alias Bourse.OptionReadiness.Baseline
  alias Bourse.OptionReadiness.Cell
  alias Bourse.OptionReadiness.Collector
  alias Bourse.OptionReadiness.Credentials
  alias Bourse.OptionReadiness.Report
  alias Bourse.OptionReadiness.VenueRow
  alias Bourse.Test.FixtureGateIsolation

  setup do
    FixtureGateIsolation.isolate!("deribit")
    :ok
  end

  # Collector calls carry `retry: false`. Several stubs below are request-count
  # state machines (`collector_speed_bump_response/2`), so a retried request
  # advances the stub's own sequence and changes the response the collector
  # sees — the assertions here are about collector logic, not HTTP retry, which
  # `http_test.exs` owns. It also drops this file from ~40s to under a second.
  @observed_at 1_800_000_000_000
  @option_symbol "BTC/USD:BTC-260131-100000-C"
  @option_id "BTC-31JAN26-100000-C"

  describe "vocabulary" do
    test "exposes the four venues, eight cells, and closed status set" do
      assert OptionReadiness.venues() == ["deribit", "okx", "bybit", "derive"]

      assert OptionReadiness.cells() == [
               :discovery,
               :greeks,
               :balances,
               :positions,
               :open_orders,
               :create_fetch_cancel,
               :preflight,
               :hedge
             ]

      assert MapSet.new(OptionReadiness.statuses()) ==
               MapSet.new([
                 :fill_ready,
                 :order_lifecycle_ready,
                 :market_unavailable,
                 :venue_degraded,
                 :client_broken,
                 :venue_unsupported,
                 :account_mode_missing,
                 :external_account_blocked
               ])

      assert OptionReadiness.judgment_statuses() == [:client_broken, :venue_degraded]
    end
  end

  describe "classify_status/1" do
    test "fill_ready requires timestamped fill, hedge, risk check, unwind and zero residual" do
      row = injected_row("bybit", fill_evidence: complete_fill_evidence())

      assert {:ok, :fill_ready} = OptionReadiness.classify_status(row)
      assert row.status == :fill_ready
      # Orthogonal short capability defaults off without short_evidence.
      refute row.capabilities.short_fill_ready
      assert row.side_status.short == :not_ready
    end

    test "partial fill evidence never becomes fill_ready" do
      partial = Map.delete(complete_fill_evidence(), :unwind)
      row = injected_row("bybit", fill_evidence: partial, lifecycle: :ok, limitation: market_limitation())

      assert row.status != :fill_ready
      assert row.status == :order_lifecycle_ready
      refute row.capabilities.short_fill_ready
    end

    test "fill_ready requires observed zero residual orders and positions" do
      incomplete = put_in(complete_fill_evidence(), [:zero_residual, :open_orders], 1)

      row = injected_row("bybit", fill_evidence: incomplete)

      refute VenueRow.fill_ready_evidence?(row)
      refute row.status == :fill_ready
    end

    test "order_lifecycle_ready needs create/fetch/cancel plus documented limitation" do
      row = injected_row("okx", lifecycle: :ok, limitation: market_limitation())

      assert row.status == :order_lifecycle_ready
      refute VenueRow.fill_ready_evidence?(row)
    end

    test "order_lifecycle without limitation is not order_lifecycle_ready" do
      row = injected_row("okx", lifecycle: :ok)

      assert is_nil(row.status)
      assert row.status_reason =~ "insufficient evidence" or row.status_reason =~ "judgment"
    end

    test "order_lifecycle requires timestamped create, fetch and cancel evidence" do
      row =
        injected_row("okx",
          cells: %{create_fetch_cancel: ok_cell(:create_fetch_cancel)},
          limitation: market_limitation()
        )

      refute VenueRow.order_lifecycle_ready?(row)
      assert is_nil(row.status)
    end

    test "empty option book records market_unavailable with observed book and never fill_ready" do
      book = %{
        observed_at: @observed_at,
        empty: true,
        two_sided: false,
        sample: [%{symbol: "BTC-OPT", bid: nil, ask: nil}]
      }

      row =
        injected_row("derive",
          lifecycle: :untested,
          book: book,
          limitation: %{kind: :market_unavailable, observed_at: @observed_at, book: book}
        )

      assert row.status == :market_unavailable
      assert row.book.observed_at == @observed_at
      refute row.status == :fill_ready

      # A lifecycle cannot upgrade an observed empty book.
      lifecycle =
        injected_row("derive",
          lifecycle: :ok,
          book: book,
          limitation: %{kind: :market_unavailable, observed_at: @observed_at, book: book}
        )

      assert lifecycle.status == :market_unavailable
      refute VenueRow.fill_ready_evidence?(lifecycle)

      filled =
        injected_row("derive",
          fill_evidence: complete_fill_evidence(),
          book: book,
          limitation: %{kind: :market_unavailable, observed_at: @observed_at, book: book}
        )

      assert filled.status == :market_unavailable
      refute filled.status == :fill_ready
    end

    test "a discovery failure is not fabricated as an observed empty book" do
      row =
        injected_row("derive",
          error_discovery: true,
          book: %{observed: false, observed_at: @observed_at, empty: true, two_sided: false}
        )

      refute VenueRow.empty_book?(row)
      assert is_nil(row.status)
      assert row.status_reason =~ "explicit AI judgment"
    end

    test "account_mode_missing and external_account_blocked honor limitation kind" do
      mode =
        injected_row("okx",
          lifecycle: :untested,
          limitation: %{kind: :account_mode_missing, observed_at: @observed_at}
        )

      blocked =
        injected_row("okx",
          lifecycle: :untested,
          limitation: %{kind: :external_account_blocked, observed_at: @observed_at, code: "51155"}
        )

      assert mode.status == :account_mode_missing
      assert blocked.status == :external_account_blocked
    end

    test "errors stay pending judgment rather than auto client_broken or venue_degraded" do
      row =
        injected_row("deribit",
          cells: %{
            discovery:
              Cell.new(:discovery,
                outcome: :error,
                observed_at: @observed_at,
                environment: "deribit-testnet",
                summary: "502 Bad Gateway",
                error: %{type: :exchange_not_available, message: "502"}
              )
          }
        )

      assert is_nil(row.status)
      assert row.status_reason =~ "explicit AI judgment"
      assert {:pending_judgment, _} = OptionReadiness.classify_status(row)
    end
  end

  describe "orthogonal short_fill_ready capability" do
    test "complete short evidence exposes short_fill_ready without replacing scalar status" do
      # Buy-side fill_ready stays the scalar status; short is orthogonal.
      row =
        injected_row("bybit",
          fill_evidence: complete_fill_evidence(),
          short_evidence: complete_short_evidence("bybit")
        )

      assert row.status == :fill_ready
      assert VenueRow.fill_ready_evidence?(row)
      assert VenueRow.short_fill_ready_evidence?(row)
      assert row.capabilities.short_fill_ready == true
      assert row.side_status.short == :short_fill_ready

      encoded = VenueRow.to_map(row)
      assert encoded["status"] == "fill_ready"
      assert encoded["capabilities"]["short_fill_ready"] == true
      assert encoded["side_status"]["short"] == "short_fill_ready"
      assert encoded["short_evidence"]["instrument"] == "BTC-14AUG26-65000-C"
    end

    test "short-only evidence does not invent buy-side fill_ready scalar status" do
      row =
        injected_row("bybit",
          lifecycle: :ok,
          limitation: market_limitation(),
          short_evidence: complete_short_evidence("bybit")
        )

      assert row.status == :order_lifecycle_ready
      refute VenueRow.fill_ready_evidence?(row)
      assert VenueRow.short_fill_ready_evidence?(row)
      assert row.capabilities.short_fill_ready == true
      assert row.side_status.short == :short_fill_ready
    end

    test "incomplete or non-ok short evidence never claims short_fill_ready" do
      missing_buyback = Map.delete(complete_short_evidence("bybit"), :buyback)
      row = injected_row("bybit", short_evidence: missing_buyback)

      refute VenueRow.short_fill_ready_evidence?(row)
      refute row.capabilities.short_fill_ready
      assert row.side_status.short == :not_ready

      not_ok =
        put_in(complete_short_evidence("bybit"), [:sell_fill, :ok], false)

      row2 = injected_row("bybit", short_evidence: not_ok)
      refute VenueRow.short_fill_ready_evidence?(row2)
      refute row2.capabilities.short_fill_ready

      out_of_order =
        put_in(complete_short_evidence("bybit"), [:buyback, :observed_at], @observed_at - 1)

      row3 = injected_row("bybit", short_evidence: out_of_order)
      refute VenueRow.short_fill_ready_evidence?(row3)
      refute row3.capabilities.short_fill_ready
    end

    test "short evidence requires provenance, order identity, prices, and margin delta" do
      base = complete_short_evidence("bybit")

      without_host = Map.delete(base, :host)
      refute VenueRow.short_fill_ready_evidence?(injected_row("bybit", short_evidence: without_host))

      without_lifecycle = Map.delete(base, :lifecycle_id)
      refute VenueRow.short_fill_ready_evidence?(injected_row("bybit", short_evidence: without_lifecycle))

      without_order_id = put_in(base, [:sell_fill], Map.delete(base.sell_fill, :order_id))
      refute VenueRow.short_fill_ready_evidence?(injected_row("bybit", short_evidence: without_order_id))

      without_price = put_in(base, [:buyback], Map.delete(base.buyback, :price))
      refute VenueRow.short_fill_ready_evidence?(injected_row("bybit", short_evidence: without_price))

      without_delta = put_in(base, [:short_margin], Map.delete(base.short_margin, :delta))
      refute VenueRow.short_fill_ready_evidence?(injected_row("bybit", short_evidence: without_delta))
    end

    test "cleanup is baseline-relative; global-zero residual is not enough" do
      base = complete_short_evidence("bybit")

      # Old buy-side zero_residual shape must never certify short cleanup.
      global_zero_cleanup = %{
        ok: true,
        observed_at: @observed_at,
        open_orders: 0,
        positions: 0
      }

      global_zero = put_in(base, [:cleanup], global_zero_cleanup)
      row = injected_row("bybit", short_evidence: global_zero)
      refute VenueRow.short_fill_ready_evidence?(row)
      refute row.capabilities.short_fill_ready

      # Unrelated residual may remain when target returns to baseline.
      with_residual =
        put_in(base, [:cleanup, :after, :unrelated_positions], [
          %{instrument: "ETHUSDT", size: 0.5}
        ])

      ready = injected_row("bybit", short_evidence: with_residual)
      assert VenueRow.short_fill_ready_evidence?(ready)
      assert ready.capabilities.short_fill_ready

      # Self-reported flags cannot override a changed target position.
      target_stuck = put_in(base, [:cleanup, :after, :target_position_size], -0.01)

      stuck = injected_row("bybit", short_evidence: target_stuck)
      refute VenueRow.short_fill_ready_evidence?(stuck)

      # Pre-existing target orders may remain, but lifecycle-created orders may not.
      baseline_with_order =
        base
        |> put_in([:cleanup, :baseline, :target_open_order_ids], ["pre-existing"])
        |> put_in([:cleanup, :after, :target_open_order_ids], ["pre-existing"])

      assert VenueRow.short_fill_ready_evidence?(injected_row("bybit", short_evidence: baseline_with_order))

      lifecycle_order_stuck =
        put_in(base, [:cleanup, :after, :target_open_order_ids], ["short-buyback-1"])

      refute VenueRow.short_fill_ready_evidence?(injected_row("bybit", short_evidence: lifecycle_order_stuck))
    end

    test "malformed or cross-context short evidence fails loudly" do
      assert_raise ArgumentError, ~r/does not match row venue/, fn ->
        injected_row("bybit", short_evidence: complete_short_evidence("deribit"))
      end

      assert_raise ArgumentError, ~r/must be a map or nil/, fn ->
        injected_row("bybit", short_evidence: "not-a-map")
      end

      assert_raise ArgumentError, ~r/timestamp must be an integer/, fn ->
        bad = put_in(complete_short_evidence("bybit"), [:sell_fill, :observed_at], "now")
        injected_row("bybit", short_evidence: bad)
      end

      assert_raise ArgumentError, ~r/host must be a non-empty string/, fn ->
        bad = Map.put(complete_short_evidence("bybit"), :host, 12_345)
        injected_row("bybit", short_evidence: bad)
      end

      assert_raise ArgumentError, ~r/does not match row environment/, fn ->
        bad = Map.put(complete_short_evidence("bybit"), :environment, "bybit-testnet")

        injected_row("bybit",
          environment: "bybit-demo",
          host: short_host_for("bybit"),
          short_evidence: bad
        )
      end

      assert_raise ArgumentError, ~r/does not match row host/, fn ->
        bad = Map.put(complete_short_evidence("bybit"), :host, "https://api-testnet.bybit.com")

        injected_row("bybit",
          environment: "bybit-demo",
          host: short_host_for("bybit"),
          short_evidence: bad
        )
      end

      assert_raise ArgumentError, ~r/sell_fill.price must be a number/, fn ->
        bad = put_in(complete_short_evidence("bybit"), [:sell_fill, :price], "2430")
        injected_row("bybit", short_evidence: bad)
      end

      assert_raise ArgumentError, ~r/buyback.lifecycle_id.*does not match/, fn ->
        bad = put_in(complete_short_evidence("bybit"), [:buyback, :lifecycle_id], "another-cycle")
        injected_row("bybit", short_evidence: bad)
      end
    end

    test "live short lifecycle evidence injects end-to-end into a written report" do
      path = "docs/option_readiness/short_lifecycle_bybit_demo_2026-07-24.json"
      assert File.exists?(path), "missing manifested short lifecycle evidence at #{path}"

      %{"short_evidence" => short_evidence, "provenance" => provenance} =
        path |> File.read!() |> Jason.decode!()

      assert provenance["venue"] == "bybit"
      assert provenance["host"] == "https://api-demo.bybit.com"
      assert is_binary(provenance["source"]) and provenance["source"] != ""

      # String-key evidence (as loaded from JSON) is accepted.
      evidence = %{
        "bybit" =>
          full_cell_map(:ok,
            environment: provenance["environment"],
            host: provenance["host"],
            fill_evidence: complete_fill_evidence(),
            short_evidence: short_evidence
          ),
        "okx" =>
          full_cell_map(:ok,
            lifecycle: :ok,
            book: %{observed_at: @observed_at, empty: true, two_sided: false},
            limitation: market_limitation()
          ),
        "derive" =>
          full_cell_map(:ok,
            lifecycle: :ok,
            book: %{observed_at: @observed_at, empty: true, two_sided: false},
            limitation: market_limitation()
          ),
        "deribit" =>
          full_cell_map(:error,
            judgment: %{
              status: :venue_degraded,
              rationale: "not part of short-side attestation",
              judged_at: @observed_at
            }
          )
      }

      dir = Path.join(System.tmp_dir!(), "option-readiness-short-#{System.unique_integer([:positive])}")

      assert {:ok, %Report{} = report} =
               OptionReadiness.run(
                 collect: false,
                 evidence: evidence,
                 observed_at: @observed_at,
                 report_dir: dir
               )

      bybit = Enum.find(report.venues, &(&1.venue == "bybit"))
      assert bybit.status == :fill_ready
      assert bybit.capabilities.short_fill_ready == true
      assert bybit.side_status.short == :short_fill_ready
      assert VenueRow.short_fill_ready_evidence?(bybit)

      encoded = Report.to_map(report)
      encoded_bybit = Enum.find(encoded["venues"], &(&1["venue"] == "bybit"))
      assert encoded_bybit["capabilities"]["short_fill_ready"] == true
      assert encoded_bybit["side_status"]["short"] == "short_fill_ready"
      assert encoded_bybit["host"] == "https://api-demo.bybit.com"
      assert encoded_bybit["short_evidence"]["sell_fill"]["price"] == 2430.0
      assert encoded_bybit["short_evidence"]["short_margin"]["delta"] == 122.0

      assert {:ok, written} = OptionReadiness.write_report(report, report.path)

      assert {:ok, reloaded} = Report.read(written)
      reloaded_bybit = Enum.find(reloaded.venues, &(&1.venue == "bybit"))
      assert reloaded_bybit.capabilities.short_fill_ready == true
      assert reloaded_bybit.side_status.short == :short_fill_ready
      assert reloaded_bybit.host == "https://api-demo.bybit.com"
    end

    test "missing short evidence never produces a synthetic short_fill_ready green" do
      row = injected_row("bybit", fill_evidence: complete_fill_evidence())
      refute is_map(row.short_evidence)
      refute row.capabilities.short_fill_ready
      assert row.side_status.short == :not_ready
      assert row.status == :fill_ready
    end
  end

  describe "apply_judgment/2" do
    test "assigns client_broken or venue_degraded only with rationale and timestamp" do
      row = injected_row("deribit", error_discovery: true)

      assert {:ok, judged} =
               OptionReadiness.apply_judgment(row, %{
                 status: :venue_degraded,
                 rationale: "Cloudflare 502 on test.deribit.com while mainnet answered 200",
                 judged_at: @observed_at + 1,
                 judge: "task-402-test"
               })

      assert judged.status == :venue_degraded
      assert judged.judgment.rationale =~ "Cloudflare 502"

      assert {:error, %Error{type: :invalid_parameters}} =
               OptionReadiness.apply_judgment(row, %{
                 status: :venue_degraded,
                 rationale: "   ",
                 judged_at: @observed_at
               })

      assert {:error, %Error{type: :invalid_parameters}} =
               OptionReadiness.apply_judgment(row, %{
                 status: :fill_ready,
                 rationale: "not a judgment status",
                 judged_at: @observed_at
               })
    end

    test "injected judgments cannot bypass rationale and timestamp validation" do
      row =
        injected_row("deribit",
          error_discovery: true,
          judgment: %{status: :client_broken, rationale: "", judged_at: nil}
        )

      assert is_nil(row.status)
      assert row.status_reason =~ "invalid explicit judgment"
    end
  end

  describe "baseline acceptance" do
    test "broken or untested cells cannot become an accepted baseline" do
      untested_cells =
        Map.new(OptionReadiness.cells(), fn name ->
          {name, Cell.new(name, outcome: :untested, observed_at: @observed_at)}
        end)

      {:ok, untested_row} = VenueRow.new("bybit", untested_cells, observed_at: @observed_at)
      untested = report_from_rows(complete_rows(untested_row))
      refute OptionReadiness.accept_baseline?(untested)
      assert Enum.any?(Baseline.rejection_reasons(untested), &(&1 =~ "untested"))

      broken =
        report_from_rows(
          complete_rows(
            injected_row("deribit",
              cells: %{
                discovery: Cell.new(:discovery, outcome: :error, observed_at: @observed_at, summary: "boom")
              }
            )
          )
        )

      refute OptionReadiness.accept_baseline?(broken)
      assert Enum.any?(Baseline.rejection_reasons(broken), &(&1 =~ "broken"))
    end

    test "complete fill_ready row with all cells exercised can be accepted" do
      row = accepted_fill_ready_row("bybit")
      report = report_from_rows(complete_rows(row))

      assert OptionReadiness.accept_baseline?(report)
      assert Baseline.rejection_reasons(report) == []
    end

    test "empty book claiming fill_ready is rejected" do
      row = accepted_fill_ready_row("bybit")

      row = %{
        row
        | book: %{observed_at: @observed_at, empty: true, two_sided: false},
          status: :fill_ready
      }

      report = report_from_rows([row])
      refute OptionReadiness.accept_baseline?(report)
      assert Enum.any?(Baseline.rejection_reasons(report), &(&1 =~ "empty option book"))
    end

    test "partial venue coverage and skipped cells are rejected" do
      partial = report_from_rows([accepted_fill_ready_row("bybit")])

      refute OptionReadiness.accept_baseline?(partial)
      assert Enum.any?(Baseline.rejection_reasons(partial), &(&1 =~ "exactly deribit"))

      skipped =
        "derive"
        |> accepted_fill_ready_row()
        |> then(fn row ->
          put_in(
            row.cells.preflight,
            Cell.new(:preflight,
              outcome: :skipped,
              observed_at: @observed_at,
              environment: "derive-demo"
            )
          )
        end)

      report = report_from_rows(complete_rows(skipped))
      refute OptionReadiness.accept_baseline?(report)
      assert Enum.any?(Baseline.rejection_reasons(report), &(&1 =~ "derive.preflight: untested"))
    end
  end

  describe "durable report" do
    test "run validates venue names before collecting" do
      assert {:error, %Error{type: :invalid_parameters, message: message}} =
               OptionReadiness.run(venues: ["not-a-venue"], collect: false)

      assert message == "unknown option readiness venues: not-a-venue"
    end

    test "prefer_injected applies explicit judgments without collecting" do
      evidence = %{"bybit" => full_cell_map(:ok, [])}
      report_dir = Path.join(System.tmp_dir!(), "option-readiness-judged-#{System.unique_integer([:positive])}")

      assert {:ok, %Report{venues: [row]} = report} =
               OptionReadiness.run(
                 venues: ["bybit"],
                 evidence: evidence,
                 judgments: %{
                   "bybit" => %{
                     status: :venue_degraded,
                     rationale: "reviewed injected evidence",
                     judged_at: @observed_at
                   }
                 },
                 prefer_injected: true,
                 observed_at: @observed_at,
                 report_dir: report_dir
               )

      assert row.status == :venue_degraded
      assert row.status_reason == "reviewed injected evidence"
      refute OptionReadiness.accept_baseline?(report)
      assert OptionReadiness.baseline_rejection_reasons(report) != []
    end

    test "run with injected evidence emits a report linking every cell" do
      evidence = %{
        "bybit" => full_cell_map(:ok, fill_evidence: complete_fill_evidence()),
        "okx" =>
          full_cell_map(:ok,
            lifecycle: :ok,
            book: %{observed_at: @observed_at, empty: true, two_sided: false},
            limitation: market_limitation()
          ),
        "derive" =>
          full_cell_map(:ok,
            lifecycle: :ok,
            book: %{observed_at: @observed_at, empty: true, two_sided: false},
            limitation: market_limitation()
          ),
        "deribit" =>
          full_cell_map(:error,
            judgment: %{
              status: :venue_degraded,
              rationale: "testnet Cloudflare 502",
              judged_at: @observed_at
            }
          )
      }

      dir = Path.join(System.tmp_dir!(), "option-readiness-#{System.unique_integer([:positive])}")

      assert {:ok, %Report{} = report} =
               OptionReadiness.run(
                 collect: false,
                 evidence: evidence,
                 observed_at: @observed_at,
                 report_dir: dir
               )

      assert length(report.venues) == 4
      assert is_binary(report.path)
      assert File.exists?(report.path)

      encoded = Report.to_map(report)
      assert encoded["schema_version"] == 1
      assert encoded["observed_at"] == @observed_at
      assert encoded["path"] == report.path

      bybit = Enum.find(encoded["venues"], &(&1["venue"] == "bybit"))
      assert bybit["status"] == "fill_ready"

      assert bybit["cells"] |> Map.keys() |> Enum.sort() ==
               OptionReadiness.cells() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      Enum.each(bybit["cells"], fn {_name, cell} ->
        assert cell["observed_at"] == @observed_at
        assert is_map(cell["evidence"]) or cell["evidence"] == %{}
      end)

      okx = Enum.find(encoded["venues"], &(&1["venue"] == "okx"))
      assert okx["status"] == "market_unavailable"
      assert okx["limitation"]["kind"] == "market_unavailable"

      deribit = Enum.find(encoded["venues"], &(&1["venue"] == "deribit"))
      assert deribit["status"] == "venue_degraded"
      assert deribit["judgment"]["rationale"] =~ "Cloudflare"

      assert {:ok, reloaded} = Report.read(report.path)
      assert length(reloaded.venues) == 4

      reloaded_bybit = Enum.find(reloaded.venues, &(&1.venue == "bybit"))
      assert reloaded_bybit.status == :fill_ready
      assert reloaded_bybit.cells.discovery.outcome == :ok
      assert reloaded_bybit.cells.discovery.observed_at == @observed_at
    end

    test "JSON encoding rejects atom and string keys that normalize to the same key" do
      assert_raise ArgumentError, ~r/duplicate JSON key after normalization/, fn ->
        Cell.stringify_keys(%{"status" => "conflict", status: :ok})
      end
    end
  end

  describe "credentials" do
    test "missing credentials fail loudly with exact setup instructions" do
      vars = [
        "DERIBIT_TESTNET_API_KEY",
        "DERIBIT_TESTNET_API_SECRET",
        "OKX_INTL_API_KEY",
        "OKX_INTL_API_SECRET",
        "OKX_INTL_PASSPHRASE",
        "BYBIT_DEMO_API_KEY",
        "BYBIT_DEMO_API_SECRET",
        "DERIVE_TESTNET_API_KEY",
        "DERIVE_TESTNET_API_SECRET"
      ]

      previous = Map.new(vars, &{&1, System.get_env(&1)})
      Enum.each(vars, &System.delete_env/1)

      try do
        for venue <- OptionReadiness.venues() do
          assert {:error, %Error{type: :authentication_error, message: message}} =
                   OptionReadiness.collect_venue(venue)

          assert message == String.trim(Credentials.setup_instructions(venue))
        end

        assert Credentials.setup_instructions("bybit") =~ "BYBIT_DEMO_API_KEY"
        assert Credentials.setup_instructions("bybit") =~ "api-demo.bybit.com"
        assert Credentials.setup_instructions("okx") =~ "OKX_INTL_PASSPHRASE"
        assert Credentials.setup_instructions("okx") =~ "www.okx.com"
        assert Credentials.setup_instructions("deribit") =~ "DERIBIT_TESTNET_API_KEY"
        assert Credentials.setup_instructions("derive") =~ "DERIVE_TESTNET_API_KEY"
      after
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end
    end
  end

  describe "collector" do
    test "captures transport failures without fabricating an observed empty market" do
      stub = unique_stub("readiness_errors")
      Req.Test.stub(stub, &Req.Test.transport_error(&1, :timeout))

      assert {:ok, row} =
               Collector.collect(
                 "deribit",
                 collector_exchange(),
                 "deribit-test",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: true
               )

      assert row.cells.discovery.outcome == :error
      assert row.cells.greeks.outcome == :empty
      assert row.cells.balances.outcome == :error
      assert row.cells.positions.outcome == :error
      assert row.cells.open_orders.outcome == :error
      assert row.cells.create_fetch_cancel.outcome == :empty
      assert row.cells.preflight.outcome == :skipped
      assert row.cells.hedge.outcome == :skipped
      assert row.book.observed == false
      assert row.book.empty == nil
      assert is_nil(row.status)
    end

    test "records timestamped create, fetch and cancel evidence through the production dispatcher" do
      stub = collector_success_stub()
      exchange = %{collector_exchange() | markets: collector_markets()}

      assert {:ok, row} =
               Collector.collect(
                 "deribit",
                 exchange,
                 "deribit-test",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: true
               )

      assert row.cells.discovery.outcome == :ok
      assert row.cells.greeks.outcome == :ok
      assert row.cells.balances.outcome == :ok
      assert row.cells.positions.outcome == :ok
      assert row.cells.open_orders.outcome == :ok
      assert row.cells.create_fetch_cancel.outcome == :ok

      lifecycle = row.cells.create_fetch_cancel.evidence

      for step <- [:create, :fetch, :cancel] do
        assert lifecycle[step].ok
        assert is_integer(lifecycle[step].observed_at)
      end

      assert lifecycle.read_back_path == :fetch_order
    end

    test "speed-bumped cancel race remains blocked until order-history reconciliation" do
      {stub, counter_key} = collector_speed_bump_stub()
      on_exit(fn -> :persistent_term.erase(counter_key) end)
      exchange = %{collector_exchange() | markets: collector_markets()}

      assert {:ok, row} =
               Collector.collect(
                 "deribit",
                 exchange,
                 "deribit-test",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: true
               )

      lifecycle = row.cells.create_fetch_cancel
      assert lifecycle.outcome == :blocked
      assert lifecycle.evidence.transient_submission
      assert lifecycle.evidence.create.status == "open"
      assert lifecycle.evidence.cancel.error.code == 11_044
      assert lifecycle.evidence.reconciliation.path == :fetch_order
      assert lifecycle.evidence.reconciliation.result.status == "closed"
      refute row.status == :fill_ready
      assert :persistent_term.get(counter_key)["/api/v2/private/buy"] == 1
    end

    test "synthetic unknown submission state blocks reconciliation without cancel or resubmit" do
      {stub, counter_key} = collector_unknown_status_stub()
      on_exit(fn -> :persistent_term.erase(counter_key) end)
      exchange = %{collector_exchange() | markets: collector_markets()}

      assert {:ok, row} =
               Collector.collect(
                 "deribit",
                 exchange,
                 "deribit-test",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: true
               )

      lifecycle = row.cells.create_fetch_cancel
      assert lifecycle.outcome == :blocked
      assert lifecycle.summary =~ "before any resubmission"
      assert lifecycle.evidence.create.error.message =~ "venue \"deribit\""
      assert lifecycle.evidence.create.error.message =~ "field \"order_state\""
      assert lifecycle.evidence.create.error.message =~ "raw value \"provider_added\""

      counts = :persistent_term.get(counter_key)
      assert counts["/api/v2/private/buy"] == 1
      assert Map.get(counts, "/api/v2/private/cancel", 0) == 0
      assert Map.get(counts, "/api/v2/private/get_order_state", 0) == 0
    end

    test "sources inverse hedge candidate price from a live ticker so hedge can size" do
      stub = collector_hedge_price_stub()
      exchange = %{collector_exchange() | markets: collector_markets_with_inverse_perp()}

      assert {:ok, row} =
               Collector.collect(
                 "deribit",
                 exchange,
                 "deribit-test",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: false,
                 max_age_ms: 86_400_000
               )

      assert row.cells.greeks.outcome == :ok
      assert row.cells.preflight.outcome == :ok
      assert row.cells.hedge.outcome == :ok
      assert is_number(row.cells.hedge.evidence.quantity)
      assert row.cells.hedge.evidence.feasible == true
      refute row.cells.hedge.summary =~ "inverse_hedge_requires_price"
    end

    test "completes missing underlying_price from a live underlying ticker without fabricating Greeks" do
      stub = collector_greeks_completion_stub(underlying_price: nil, source_timestamp: @observed_at)
      exchange = %{collector_exchange() | markets: collector_markets_with_inverse_perp()}

      assert {:ok, row} =
               Collector.collect(
                 "deribit",
                 exchange,
                 "deribit-test",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: false,
                 max_age_ms: 86_400_000
               )

      # greeks cell still reports the raw venue payload (nil underlying); completion is preflight-only
      assert row.cells.greeks.outcome == :ok
      assert row.cells.greeks.evidence.underlying_price == nil
      assert row.cells.preflight.outcome == :ok
      assert row.cells.hedge.outcome in [:ok, :blocked]
    end

    test "does not use an underlying ticker timestamp as the Greeks provider timestamp" do
      stub = collector_greeks_completion_stub(underlying_price: 100_000.0, source_timestamp: nil)
      exchange = %{collector_exchange() | markets: collector_markets_with_inverse_perp()}

      assert {:ok, row} =
               Collector.collect(
                 "deribit",
                 exchange,
                 "deribit-test",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: false,
                 max_age_ms: 86_400_000
               )

      assert row.cells.greeks.outcome == :ok
      assert row.cells.greeks.evidence.source_timestamp == nil
      assert row.cells.preflight.outcome == :skipped
      assert row.cells.preflight.summary =~ "missing source_timestamp"
    end

    test "skips preflight honestly when core Greeks are missing — never fabricates delta/gamma/theta/vega" do
      stub = collector_incomplete_core_greeks_stub()
      exchange = %{collector_exchange() | markets: collector_markets_with_inverse_perp()}

      assert {:ok, row} =
               Collector.collect(
                 "deribit",
                 exchange,
                 "deribit-test",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: false
               )

      assert row.cells.greeks.outcome == :ok
      assert row.cells.preflight.outcome == :skipped
      assert row.cells.hedge.outcome == :skipped
      assert row.cells.preflight.summary =~ "missing"
      assert row.cells.preflight.summary =~ "delta" or row.cells.preflight.summary =~ "gamma"
    end

    test "uses fetch_open_orders read-back when fetchOrder is unsupported and requires zero residual" do
      stub = collector_open_orders_lifecycle_stub()
      base = collector_exchange()

      exchange = %{
        base
        | markets: collector_markets(),
          has: Map.put(base.has, "fetchOrder", false)
      }

      assert {:ok, row} =
               Collector.collect(
                 "derive",
                 exchange,
                 "derive-demo",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: true
               )

      lifecycle = row.cells.create_fetch_cancel
      assert lifecycle.outcome == :ok
      assert lifecycle.evidence.read_back_path == :fetch_open_orders
      assert lifecycle.evidence.fetch.ok
      assert lifecycle.evidence.cancel.ok
      residual = lifecycle.evidence.residual_open_orders
      assert residual.ok
      assert residual.value =~ "count: 0"
    end

    test "marks lifecycle error when open-orders read-back cannot find the created order" do
      stub = collector_missing_open_order_stub()
      base = collector_exchange()

      exchange = %{
        base
        | markets: collector_markets(),
          has: Map.put(base.has, "fetchOrder", false)
      }

      assert {:ok, row} =
               Collector.collect(
                 "derive",
                 exchange,
                 "derive-demo",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: true
               )

      lifecycle = row.cells.create_fetch_cancel
      assert lifecycle.outcome == :error
      assert lifecycle.evidence.read_back_path == :fetch_open_orders
      assert lifecycle.evidence.fetch.ok == false
      assert lifecycle.evidence.fetch.error.type == :order_not_found
    end

    test "marks lifecycle error when residual open orders remain after cancel" do
      stub = collector_residual_resting_stub()
      base = collector_exchange()

      exchange = %{
        base
        | markets: collector_markets(),
          has: Map.put(base.has, "fetchOrder", false)
      }

      assert {:ok, row} =
               Collector.collect(
                 "derive",
                 exchange,
                 "derive-demo",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: true
               )

      lifecycle = row.cells.create_fetch_cancel
      assert lifecycle.outcome == :error
      assert lifecycle.evidence.read_back_path == :fetch_open_orders
      assert lifecycle.evidence.cancel.ok
      assert lifecycle.error.residual_open_orders == 1
    end

    test "records create failure evidence without inventing a successful lifecycle" do
      stub = collector_create_fail_stub()
      exchange = %{collector_exchange() | markets: collector_markets()}

      assert {:ok, row} =
               Collector.collect(
                 "deribit",
                 exchange,
                 "deribit-test",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: true
               )

      lifecycle = row.cells.create_fetch_cancel
      assert lifecycle.outcome == :error
      assert lifecycle.evidence.create.ok == false
      assert is_map(lifecycle.error)
    end

    test "does not relabel local observation time as a missing provider timestamp" do
      stub = collector_ticker_no_completion_stub()
      exchange = %{collector_exchange() | markets: collector_markets_with_inverse_perp()}

      assert {:ok, row} =
               Collector.collect(
                 "deribit",
                 exchange,
                 "deribit-test",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: false
               )

      assert row.cells.greeks.outcome == :ok
      assert row.cells.preflight.outcome == :skipped
      assert row.cells.preflight.summary =~ "missing source_timestamp"
      assert row.cells.preflight.summary =~ "live ticker completion attempted"
    end

    test "records greeks cell error when venue Greeks fetch fails without inventing values" do
      stub = collector_greeks_error_stub()
      exchange = %{collector_exchange() | markets: collector_markets()}

      assert {:ok, row} =
               Collector.collect(
                 "deribit",
                 exchange,
                 "deribit-test",
                 [plug: {Req.Test, stub}, retry: false],
                 @observed_at,
                 mutate: false
               )

      assert row.cells.discovery.outcome == :ok
      assert row.cells.greeks.outcome == :error
      assert row.cells.preflight.outcome == :skipped
      assert row.cells.hedge.outcome == :skipped
      assert row.cells.preflight.summary =~ "greeks cell not ok"
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp complete_fill_evidence do
    ts = @observed_at

    %{
      fill: %{ok: true, observed_at: ts, order_id: "fill-1"},
      hedge: %{ok: true, observed_at: ts, order_id: "hedge-1"},
      risk_check: %{ok: true, observed_at: ts, residual_delta: 0.0},
      unwind: %{ok: true, observed_at: ts, option_close: "c1", hedge_close: "c2"},
      zero_residual: %{ok: true, observed_at: ts, open_orders: 0, positions: 0}
    }
  end

  defp complete_short_evidence(venue) when is_binary(venue) do
    ts = @observed_at
    instrument = "BTC-14AUG26-65000-C"

    %{
      venue: venue,
      environment: "#{venue}-demo",
      host: short_host_for(venue),
      instrument: instrument,
      lifecycle_id: "#{venue}-short-cycle-1",
      sell_fill: %{
        ok: true,
        observed_at: ts,
        order_id: "short-sell-1",
        instrument: instrument,
        lifecycle_id: "#{venue}-short-cycle-1",
        side: "sell",
        price: 2430.0,
        amount: 0.01
      },
      short_margin: %{
        ok: true,
        observed_at: ts + 1,
        instrument: instrument,
        lifecycle_id: "#{venue}-short-cycle-1",
        before: 0.0,
        after: 122.0,
        delta: 122.0,
        unit: "USDT"
      },
      buyback: %{
        ok: true,
        observed_at: ts + 2,
        order_id: "short-buyback-1",
        instrument: instrument,
        lifecycle_id: "#{venue}-short-cycle-1",
        side: "buy",
        price: 2430.0,
        amount: 0.01
      },
      cleanup: %{
        ok: true,
        observed_at: ts + 3,
        target_instrument: instrument,
        lifecycle_id: "#{venue}-short-cycle-1",
        lifecycle_order_ids: ["short-sell-1", "short-buyback-1"],
        baseline: %{
          target_position_size: 0,
          target_open_order_ids: [],
          positions: [],
          open_orders: [],
          unrelated_positions: [%{instrument: "BTCUSDT", size: 0.001}]
        },
        after: %{
          target_position_size: 0,
          target_open_order_ids: [],
          positions: [],
          open_orders: [],
          unrelated_positions: [%{instrument: "BTCUSDT", size: 0.001}]
        }
      }
    }
  end

  defp short_host_for("bybit"), do: "https://api-demo.bybit.com"
  defp short_host_for("deribit"), do: "https://test.deribit.com"
  defp short_host_for("okx"), do: "https://www.okx.com"
  defp short_host_for("derive"), do: "https://api-demo.lyra.finance"
  defp short_host_for(other), do: "https://example.test/#{other}"

  defp market_limitation do
    %{
      kind: :market_unavailable,
      observed_at: @observed_at,
      detail: "no two-sided ATM book"
    }
  end

  defp ok_cell(name, env \\ "test") do
    Cell.new(name,
      outcome: :ok,
      observed_at: @observed_at,
      environment: env,
      summary: "#{name} ok",
      evidence: %{probe: true}
    )
  end

  defp full_cells(outcome \\ :ok) do
    Map.new(OptionReadiness.cells(), fn name ->
      cell =
        case outcome do
          :ok -> ok_cell(name)
          :error -> Cell.new(name, outcome: :error, observed_at: @observed_at, summary: "err")
          :untested -> Cell.new(name, outcome: :untested, observed_at: @observed_at)
        end

      {name, cell}
    end)
  end

  defp full_cell_map(outcome, opts) do
    environment = Keyword.get(opts, :environment, "test")

    cells =
      Map.new(OptionReadiness.cells(), fn name ->
        cell_outcome =
          if name == :create_fetch_cancel and Keyword.has_key?(opts, :lifecycle) do
            Keyword.fetch!(opts, :lifecycle)
          else
            outcome
          end

        evidence =
          if name == :create_fetch_cancel and cell_outcome == :ok do
            complete_lifecycle_evidence()
          else
            %{"probe" => true}
          end

        {name,
         %{
           "outcome" => Atom.to_string(cell_outcome),
           "observed_at" => @observed_at,
           "environment" => environment,
           "summary" => "#{name}",
           "evidence" => evidence
         }}
      end)

    cells
    |> Map.put("environment", environment)
    |> maybe_put("host", Keyword.get(opts, :host))
    |> maybe_put("fill_evidence", Keyword.get(opts, :fill_evidence))
    |> maybe_put("short_evidence", Keyword.get(opts, :short_evidence))
    |> maybe_put("limitation", Keyword.get(opts, :limitation))
    |> maybe_put("book", Keyword.get(opts, :book))
    |> maybe_put("judgment", Keyword.get(opts, :judgment))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp collector_exchange do
    exchange =
      Exchange.new!("deribit",
        api_key: "readiness-key",
        secret: "readiness-secret"
      )

    %{exchange | has: Map.put(exchange.has, "fetchOptionChain", false)}
  end

  @perp_symbol "BTC/USD:BTC"
  @perp_id "BTC-PERPETUAL"

  defp collector_markets do
    [
      %Market{
        id: @option_id,
        symbol: @option_symbol,
        base: "BTC",
        quote: "USD",
        settle: "BTC",
        type: "option",
        option: true,
        contract: true,
        active: true,
        quantity_unit: "base",
        native_quantity_unit: "base",
        native_amount_step: 0.1,
        contract_size: 1,
        precision: %{"amount" => 0.1},
        strike: 100_000,
        expiry: 1_769_817_600_000,
        option_type: "call",
        info: %{"instrument_name" => @option_id}
      }
    ]
  end

  defp collector_markets_with_inverse_perp do
    collector_markets() ++
      [
        %Market{
          id: @perp_id,
          symbol: @perp_symbol,
          base: "BTC",
          quote: "USD",
          settle: "BTC",
          type: "swap",
          swap: true,
          contract: true,
          inverse: true,
          linear: false,
          active: true,
          contract_size: 10.0,
          precision: %{"amount" => 10.0, "price" => 0.5},
          info: %{"instrument_name" => @perp_id}
        }
      ]
  end

  defp collector_success_stub do
    stub = unique_stub("readiness_success")

    Req.Test.stub(stub, fn conn ->
      body =
        case conn.request_path do
          "/api/v2/public/ticker" ->
            collector_greeks_body()

          "/api/v2/private/get_account_summaries" ->
            recorded_body("fetch_balance")

          "/api/v2/private/get_positions" ->
            recorded_body("fetch_positions")

          "/api/v2/private/get_open_orders_by_currency" ->
            recorded_body("fetch_open_orders")

          "/api/v2/private/buy" ->
            rpc_result(%{"order" => collector_order("open"), "trades" => []})

          "/api/v2/private/get_order_state" ->
            rpc_result(collector_order("open"))

          "/api/v2/private/cancel" ->
            rpc_result(collector_order("cancelled"))
        end

      Req.Test.json(conn, body)
    end)

    stub
  end

  defp collector_speed_bump_stub do
    stub = unique_stub("readiness_speed_bump")
    counter_key = {__MODULE__, stub, :counts}
    :persistent_term.put(counter_key, %{})

    Req.Test.stub(stub, fn conn ->
      count = increment_request_count(counter_key, conn.request_path)
      Req.Test.json(conn, collector_speed_bump_response(conn.request_path, count))
    end)

    {stub, counter_key}
  end

  defp collector_speed_bump_response("/api/v2/public/ticker", _count), do: collector_greeks_body()

  defp collector_speed_bump_response("/api/v2/private/get_account_summaries", _count), do: recorded_body("fetch_balance")

  defp collector_speed_bump_response("/api/v2/private/get_positions", _count), do: recorded_body("fetch_positions")

  defp collector_speed_bump_response(path, _count)
       when path in ["/api/v2/private/get_open_orders_by_currency", "/api/v2/private/get_open_orders_by_instrument"],
       do: rpc_result([])

  defp collector_speed_bump_response("/api/v2/private/buy", _count),
    do: rpc_result(%{"order" => collector_order("speed_bumped"), "trades" => []})

  defp collector_speed_bump_response("/api/v2/private/get_order_state", 1), do: rpc_result(collector_order("open"))

  defp collector_speed_bump_response("/api/v2/private/get_order_state", _count),
    do: rpc_result(Map.put(collector_order("filled"), "filled_amount", 0.1))

  defp collector_speed_bump_response("/api/v2/private/cancel", _count) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => 11_044, "message" => "not_open_order"},
      "testnet" => true
    }
  end

  defp collector_unknown_status_stub do
    stub = unique_stub("readiness_unknown_status")
    counter_key = {__MODULE__, stub, :counts}
    :persistent_term.put(counter_key, %{})

    Req.Test.stub(stub, fn conn ->
      increment_request_count(counter_key, conn.request_path)

      body =
        case conn.request_path do
          "/api/v2/public/ticker" ->
            collector_greeks_body()

          "/api/v2/private/get_account_summaries" ->
            recorded_body("fetch_balance")

          "/api/v2/private/get_positions" ->
            recorded_body("fetch_positions")

          "/api/v2/private/get_open_orders_by_currency" ->
            rpc_result([])

          "/api/v2/private/buy" ->
            rpc_result(%{"order" => collector_order("provider_added"), "trades" => []})
        end

      Req.Test.json(conn, body)
    end)

    {stub, counter_key}
  end

  defp increment_request_count(counter_key, path) do
    counts = :persistent_term.get(counter_key)
    count = Map.get(counts, path, 0) + 1
    :persistent_term.put(counter_key, Map.put(counts, path, count))
    count
  end

  defp collector_hedge_price_stub do
    stub = unique_stub("readiness_hedge_price")

    Req.Test.stub(stub, fn conn ->
      body = collector_hedge_price_response(conn.request_path, conn.query_string)
      Req.Test.json(conn, body)
    end)

    stub
  end

  defp collector_hedge_price_response("/api/v2/public/ticker", query),
    do: collector_ticker_response(query, collector_greeks_body())

  defp collector_hedge_price_response("/api/v2/private/get_account_summaries", _query), do: recorded_body("fetch_balance")

  defp collector_hedge_price_response("/api/v2/private/get_positions", _query), do: recorded_body("fetch_positions")

  defp collector_hedge_price_response("/api/v2/private/get_open_orders_by_currency", _query), do: rpc_result([])

  defp collector_hedge_price_response(_path, _query), do: rpc_result(%{})

  defp collector_greeks_completion_stub(opts) do
    underlying = Keyword.get(opts, :underlying_price, 100_000.0)
    source_ts = Keyword.get(opts, :source_timestamp, @observed_at)
    stub = unique_stub("readiness_greeks_complete")

    Req.Test.stub(stub, fn conn ->
      body = collector_greeks_completion_response(conn.request_path, conn.query_string, underlying, source_ts)
      Req.Test.json(conn, body)
    end)

    stub
  end

  defp collector_greeks_completion_response("/api/v2/public/ticker", query, underlying, source_ts) do
    option_body = collector_greeks_body(underlying_price: underlying, source_timestamp: source_ts)
    collector_ticker_response(query, option_body)
  end

  defp collector_greeks_completion_response("/api/v2/private/get_account_summaries", _query, _underlying, _source_ts),
    do: recorded_body("fetch_balance")

  defp collector_greeks_completion_response("/api/v2/private/get_positions", _query, _underlying, _source_ts),
    do: recorded_body("fetch_positions")

  defp collector_greeks_completion_response(
         "/api/v2/private/get_open_orders_by_currency",
         _query,
         _underlying,
         _source_ts
       ), do: rpc_result([])

  defp collector_greeks_completion_response(_path, _query, _underlying, _source_ts), do: rpc_result(%{})

  defp collector_ticker_response(query, option_body) do
    if query =~ @perp_id, do: collector_perp_ticker_body(), else: option_body
  end

  defp collector_incomplete_core_greeks_stub do
    stub = unique_stub("readiness_incomplete_core")

    Req.Test.stub(stub, fn conn ->
      body =
        case conn.request_path do
          "/api/v2/public/ticker" ->
            # Greeks payload with nil delta/gamma — completion must not invent them
            rpc_result(%{
              "best_bid_price" => 0.1,
              "best_ask_price" => 0.2,
              "instrument_name" => @option_id,
              "timestamp" => @observed_at,
              "underlying_price" => 100_000.0,
              "greeks" => %{
                "delta" => nil,
                "gamma" => nil,
                "theta" => -0.3,
                "vega" => 0.2
              }
            })

          "/api/v2/private/get_account_summaries" ->
            recorded_body("fetch_balance")

          "/api/v2/private/get_positions" ->
            recorded_body("fetch_positions")

          "/api/v2/private/get_open_orders_by_currency" ->
            rpc_result([])

          _other ->
            collector_perp_ticker_body()
        end

      Req.Test.json(conn, body)
    end)

    stub
  end

  defp collector_open_orders_lifecycle_stub do
    stub = unique_stub("readiness_open_orders_lifecycle")
    # After create, open-order list includes the order; after cancel, it is empty.
    # Phase flips on cancel so residual attestation sees zero resting.
    # Deribit routes symbol-scoped open-order reads to by_instrument; currency
    # scoped (pre-lifecycle open_orders cell) still hits by_currency.
    :persistent_term.put({__MODULE__, stub}, :before_cancel)

    Req.Test.stub(stub, fn conn ->
      body = collector_open_orders_lifecycle_response(conn.request_path, stub)
      Req.Test.json(conn, body)
    end)

    stub
  end

  defp collector_open_orders_lifecycle_response("/api/v2/public/ticker", _stub), do: collector_greeks_body()

  defp collector_open_orders_lifecycle_response("/api/v2/private/get_account_summaries", _stub),
    do: recorded_body("fetch_balance")

  defp collector_open_orders_lifecycle_response("/api/v2/private/get_positions", _stub),
    do: recorded_body("fetch_positions")

  defp collector_open_orders_lifecycle_response("/api/v2/private/buy", _stub),
    do: rpc_result(%{"order" => collector_order("open"), "trades" => []})

  defp collector_open_orders_lifecycle_response(path, stub)
       when path in ["/api/v2/private/get_open_orders_by_currency", "/api/v2/private/get_open_orders_by_instrument"] do
    case :persistent_term.get({__MODULE__, stub}) do
      :before_cancel -> rpc_result([collector_order("open")])
      :after_cancel -> rpc_result([])
    end
  end

  defp collector_open_orders_lifecycle_response("/api/v2/private/cancel", stub) do
    :persistent_term.put({__MODULE__, stub}, :after_cancel)
    rpc_result(collector_order("cancelled"))
  end

  defp collector_open_orders_lifecycle_response("/api/v2/private/get_order_state", _stub) do
    %{"jsonrpc" => "2.0", "error" => %{"code" => -32_601, "message" => "unexpected fetch_order"}}
  end

  defp collector_greeks_body(opts \\ []) do
    underlying = Keyword.get(opts, :underlying_price, 100_000.0)
    source_ts = Keyword.get(opts, :source_timestamp, System.system_time(:millisecond))

    payload = %{
      "best_bid_price" => 0.1,
      "best_ask_price" => 0.2,
      "instrument_name" => @option_id,
      "mark_iv" => 0.6,
      "open_interest" => 12.5,
      "greeks" => %{
        "delta" => 0.5,
        "gamma" => 0.01,
        "rho" => 0.1,
        "theta" => -0.3,
        "vega" => 0.2
      }
    }

    payload =
      if is_nil(underlying) do
        Map.put(payload, "underlying_price", nil)
      else
        Map.put(payload, "underlying_price", underlying)
      end

    payload =
      if is_nil(source_ts) do
        Map.delete(payload, "timestamp")
      else
        Map.put(payload, "timestamp", source_ts)
      end

    rpc_result(payload)
  end

  defp collector_perp_ticker_body do
    rpc_result(%{
      "instrument_name" => @perp_id,
      "best_bid_price" => 99_990.0,
      "best_ask_price" => 100_010.0,
      "last_price" => 100_000.0,
      "mark_price" => 100_005.0,
      "index_price" => 100_000.0,
      "timestamp" => System.system_time(:millisecond)
    })
  end

  defp collector_missing_open_order_stub do
    stub = unique_stub("readiness_missing_open")

    Req.Test.stub(stub, fn conn ->
      body =
        case conn.request_path do
          "/api/v2/public/ticker" ->
            collector_greeks_body()

          "/api/v2/private/get_account_summaries" ->
            recorded_body("fetch_balance")

          "/api/v2/private/get_positions" ->
            recorded_body("fetch_positions")

          "/api/v2/private/buy" ->
            rpc_result(%{"order" => collector_order("open"), "trades" => []})

          path
          when path in [
                 "/api/v2/private/get_open_orders_by_currency",
                 "/api/v2/private/get_open_orders_by_instrument"
               ] ->
            # Never includes the created order id
            rpc_result([])

          "/api/v2/private/cancel" ->
            rpc_result(collector_order("cancelled"))

          _other ->
            rpc_result(%{})
        end

      Req.Test.json(conn, body)
    end)

    stub
  end

  defp collector_residual_resting_stub do
    stub = unique_stub("readiness_residual_resting")

    Req.Test.stub(stub, fn conn ->
      body = collector_residual_resting_response(conn.request_path)
      Req.Test.json(conn, body)
    end)

    stub
  end

  defp collector_residual_resting_response("/api/v2/public/ticker"), do: collector_greeks_body()

  defp collector_residual_resting_response("/api/v2/private/get_account_summaries"), do: recorded_body("fetch_balance")

  defp collector_residual_resting_response("/api/v2/private/get_positions"), do: recorded_body("fetch_positions")

  defp collector_residual_resting_response("/api/v2/private/buy"),
    do: rpc_result(%{"order" => collector_order("open"), "trades" => []})

  defp collector_residual_resting_response(path)
       when path in ["/api/v2/private/get_open_orders_by_currency", "/api/v2/private/get_open_orders_by_instrument"],
       do: rpc_result([collector_order("open")])

  defp collector_residual_resting_response("/api/v2/private/cancel"), do: rpc_result(collector_order("cancelled"))

  defp collector_residual_resting_response(_path), do: rpc_result(%{})

  defp collector_create_fail_stub do
    stub = unique_stub("readiness_create_fail")

    Req.Test.stub(stub, fn conn ->
      body =
        case conn.request_path do
          "/api/v2/public/ticker" ->
            collector_greeks_body()

          "/api/v2/private/get_account_summaries" ->
            recorded_body("fetch_balance")

          "/api/v2/private/get_positions" ->
            recorded_body("fetch_positions")

          "/api/v2/private/get_open_orders_by_currency" ->
            rpc_result([])

          "/api/v2/private/buy" ->
            %{
              "jsonrpc" => "2.0",
              "error" => %{"code" => 13_028, "message" => "rejected for test"},
              "testnet" => true
            }

          _other ->
            rpc_result(%{})
        end

      Req.Test.json(conn, body)
    end)

    stub
  end

  defp collector_ticker_no_completion_stub do
    stub = unique_stub("readiness_no_completion")

    Req.Test.stub(stub, fn conn ->
      body = collector_ticker_no_completion_response(conn.request_path, conn.query_string)
      Req.Test.json(conn, body)
    end)

    stub
  end

  defp collector_ticker_no_completion_response("/api/v2/public/ticker", query) do
    option_body = collector_greeks_body(underlying_price: 100_000.0, source_timestamp: nil)
    collector_no_timestamp_ticker_response(query, option_body)
  end

  defp collector_ticker_no_completion_response("/api/v2/private/get_account_summaries", _query),
    do: recorded_body("fetch_balance")

  defp collector_ticker_no_completion_response("/api/v2/private/get_positions", _query),
    do: recorded_body("fetch_positions")

  defp collector_ticker_no_completion_response("/api/v2/private/get_open_orders_by_currency", _query), do: rpc_result([])

  defp collector_ticker_no_completion_response(_path, _query), do: rpc_result(%{})

  defp collector_no_timestamp_ticker_response(query, option_body) do
    if query =~ @perp_id, do: collector_no_timestamp_perp_body(), else: option_body
  end

  defp collector_no_timestamp_perp_body do
    rpc_result(%{
      "instrument_name" => @perp_id,
      "best_bid_price" => 0,
      "best_ask_price" => 0,
      "last_price" => 0,
      "timestamp" => nil
    })
  end

  defp collector_greeks_error_stub do
    stub = unique_stub("readiness_greeks_error")

    Req.Test.stub(stub, fn conn ->
      body =
        case conn.request_path do
          "/api/v2/public/ticker" ->
            %{
              "jsonrpc" => "2.0",
              "error" => %{"code" => 10_004, "message" => "greeks unavailable for test"},
              "testnet" => true
            }

          "/api/v2/private/get_account_summaries" ->
            recorded_body("fetch_balance")

          "/api/v2/private/get_positions" ->
            recorded_body("fetch_positions")

          "/api/v2/private/get_open_orders_by_currency" ->
            rpc_result([])

          _other ->
            rpc_result(%{})
        end

      Req.Test.json(conn, body)
    end)

    stub
  end

  defp collector_order(state) do
    %{
      "amount" => 0.1,
      "average_price" => 0,
      "creation_timestamp" => @observed_at,
      "direction" => "buy",
      "filled_amount" => 0,
      "instrument_name" => @option_id,
      "last_update_timestamp" => @observed_at,
      "order_id" => "readiness-order",
      "order_state" => state,
      "order_type" => "limit",
      "original_order_type" => "limit",
      "post_only" => true,
      "price" => 0.0001,
      "time_in_force" => "good_til_cancelled"
    }
  end

  defp recorded_body(method) do
    "test/fixtures/responses/deribit/#{method}.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("body")
  end

  defp rpc_result(result), do: %{"jsonrpc" => "2.0", "result" => result, "testnet" => true}
  defp unique_stub(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

  defp injected_row(venue, opts) do
    cells =
      full_cells()
      |> Map.merge(Keyword.get(opts, :cells, %{}))
      |> put_lifecycle(Keyword.get(opts, :lifecycle))
      |> put_discovery_error(Keyword.get(opts, :error_discovery))

    short_evidence = Keyword.get(opts, :short_evidence)

    {:ok, row} =
      VenueRow.new(venue, cells,
        observed_at: @observed_at,
        environment:
          Keyword.get(opts, :environment) ||
            evidence_field(short_evidence, :environment) ||
            "#{venue}-env",
        host: Keyword.get(opts, :host) || evidence_field(short_evidence, :host),
        fill_evidence: Keyword.get(opts, :fill_evidence),
        short_evidence: short_evidence,
        limitation: Keyword.get(opts, :limitation),
        book: Keyword.get(opts, :book),
        judgment: Keyword.get(opts, :judgment)
      )

    row
  end

  defp evidence_field(evidence, key) when is_map(evidence),
    do: Map.get(evidence, key) || Map.get(evidence, Atom.to_string(key))

  defp evidence_field(_evidence, _key), do: nil

  defp put_lifecycle(cells, nil), do: cells

  defp put_lifecycle(cells, outcome) do
    cell = %{ok_cell(:create_fetch_cancel) | outcome: outcome}
    cell = if outcome == :ok, do: %{cell | evidence: complete_lifecycle_evidence()}, else: cell
    Map.put(cells, :create_fetch_cancel, cell)
  end

  defp put_discovery_error(cells, false), do: cells
  defp put_discovery_error(cells, nil), do: cells

  defp put_discovery_error(cells, true) do
    cell = Cell.new(:discovery, outcome: :error, observed_at: @observed_at, summary: "502")
    Map.put(cells, :discovery, cell)
  end

  defp accepted_fill_ready_row(venue) do
    cells = full_cells(:ok)

    {:ok, row} =
      VenueRow.new(venue, cells,
        observed_at: @observed_at,
        environment: "#{venue}-demo",
        fill_evidence: complete_fill_evidence(),
        book: %{observed_at: @observed_at, empty: false, two_sided: true, two_sided_count: 3}
      )

    row
  end

  defp report_from_rows(rows) do
    Report.new(rows, @observed_at)
  end

  defp complete_lifecycle_evidence do
    %{
      create: %{ok: true, observed_at: @observed_at, id: "order-1"},
      fetch: %{ok: true, observed_at: @observed_at, id: "order-1"},
      cancel: %{ok: true, observed_at: @observed_at, id: "order-1"}
    }
  end

  defp complete_rows(replacement) do
    OptionReadiness.venues()
    |> Map.new(fn venue ->
      row = if venue == replacement.venue, do: replacement, else: accepted_fill_ready_row(venue)
      {venue, row}
    end)
    |> Map.values()
  end
end
