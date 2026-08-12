defmodule Bourse.CarveRegisterConsistencyTest do
  use ExUnit.Case, async: true

  @legacy_register_path Path.expand("../../docs/authored-specs.md", __DIR__)
  @register_paths "../../docs/authored-spec-carves/*.md"
                  |> Path.expand(__DIR__)
                  |> Path.wildcard()
                  |> Enum.sort()
  @ledger_path Path.expand("../../docs/prod-verification-ledger.md", __DIR__)
  @changelog_path Path.expand("../../CHANGELOG.md", __DIR__)
  @responses_manifest_path Path.expand("../fixtures/responses/_manifest.json", __DIR__)
  @registered_response_fixtures @responses_manifest_path
                                |> File.read!()
                                |> Jason.decode!()
                                |> Map.fetch!("fixtures")
                                |> MapSet.new(&Path.join("test/fixtures/responses", &1))
  @strict_recording_task 603
  @observed_evidence_kinds ~w(live_venue provider_shaped recorded_real_exchange recorded_venue)
  @strict_observed_evidence_kinds ~w(live_venue provider_shaped recorded_venue)
  @reference_paths [@legacy_register_path | @register_paths] ++ [@changelog_path]
  @legacy_ids MapSet.new(~w(
                B1 B2 B3
                C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 C11 C12 C13 C14 C15 C15a C16 C17 C17a C18 C19
                C20 C21 C22 C23 C24 C25 C26 C27 C28 C29 C30 C31 C32 C33 C34 C35 C36 C37 C38 C39
              ))
  @evidence_fields ~w(carve_id date semantic_source observed_evidence compatibility_reference resolved_tier)
  @completeness_claims %{
    "alpaca.md" => "**Canonical for this venue.**",
    "binance.md" => "**Canonical for this venue.**",
    "binancecoinm.md" => "**Canonical for Binance COIN-M's complete authored REST surface.**",
    "binanceusdm.md" => "**Canonical for this venue.**",
    "bybit.md" => "**Canonical for this venue.**",
    "coinbaseexchange.md" => "**Canonical for this venue.**",
    "deribit.md" => "**Canonical for this venue.**",
    "derive.md" => "**Canonical for this venue.**",
    "global.md" => "**Canonical for cross-venue carves.**",
    "hyperliquid.md" => "**Canonical for this venue.**",
    "lighter.md" => "**Canonical for Lighter's complete authored REST surface.**",
    "okx.md" => "**Canonical for this venue.**"
  }
  @binding_rows [
    {"C-T342", "okx.md", "| `withdraw` | `ccy` / `amt` / `toAddr` |"},
    {"C-T343", "bybit.md", "| `fetchVolatilityHistory` | `baseCoin` |"},
    {"C-T344", "deribit.md", "| `fetchOrderTrades` | `order_id` |"}
  ]
  for register_path <- @register_paths do
    @external_resource register_path
  end

  @external_resource @legacy_register_path
  @external_resource @ledger_path
  @external_resource @changelog_path
  @external_resource @responses_manifest_path

  test "the carve register has unique ids" do
    assert [] == @register_paths |> read_register() |> register_ids() |> duplicate_ids()
  end

  test "current evidence statuses agree with closed ledger claims" do
    records = @register_paths |> read_sources() |> evidence_status_records()
    statuses = current_evidence_statuses(records)

    assert [] == evidence_status_errors(records)
    assert [] == ledger_tier_errors(closed_ledger_claims(File.read!(@ledger_path)), statuses)
  end

  test "prose evidence claims have a machine-readable current status" do
    sources = read_sources(@register_paths)
    statuses = sources |> evidence_status_records() |> current_evidence_statuses()

    assert [] == prose_claim_status_errors(sources, statuses)
  end

  test "every register states its canonical completeness scope" do
    assert [] == @register_paths |> read_sources() |> completeness_claim_errors()
  end

  test "residual binding tables live only in their owning venue registers" do
    legacy = File.read!(@legacy_register_path)
    sources = read_sources(@register_paths)

    Enum.each(@binding_rows, fn {carve_id, basename, binding_row} ->
      register =
        Enum.find_value(sources, fn {path, content} ->
          if Path.basename(path) == basename, do: content
        end)

      assert carve_id in register_ids(register)
      assert String.contains?(register, binding_row)
      refute String.contains?(legacy, binding_row)
      assert String.contains?(legacy, carve_id)
    end)
  end

  # Qualified forms ("Oracle (tier 2): ...") are banned too: the label reads as a correctness
  # claim whatever follows it, and the tier now lives in the evidence status block.
  test "carve registers do not use an Oracle label" do
    assert [] == @register_paths |> read_sources() |> oracle_labels()
  end

  test "alpaca live supersessions resolve the stale verification prose" do
    statuses = @register_paths |> read_sources() |> evidence_status_records() |> current_evidence_statuses()

    assert 1 == statuses["C-T428a"]["resolved_tier"]
    assert 1 == statuses["C-T428b"]["resolved_tier"]
    assert 1 == statuses["C-T428c"]["resolved_tier"]
    assert 2 == statuses["C-T428d"]["resolved_tier"]
    assert Enum.all?(~w(C-T429a C-T429b C-T429c C-T429d C-T429e), &(statuses[&1]["resolved_tier"] == 1))
    assert statuses["C-T429f"]["resolved_tier"] == 2
  end

  test "the historical doctrine contains pointers, not canonical carve headings" do
    assert [] == @legacy_register_path |> File.read!() |> register_ids()
  end

  test "new carve ids are task-scoped and legacy ids remain append-only" do
    register = read_register(@register_paths)
    registered_ids = register_ids(register)

    assert [] == unexpected_legacy_ids(registered_ids)
    assert [] == task_scoped_id_errors(register)
  end

  test "every documented carve reference resolves to one register entry" do
    registered_ids = @register_paths |> read_register() |> register_ids() |> MapSet.new()

    assert [] == unresolved_references(read_sources(@reference_paths), registered_ids)
  end

  test "duplicate ids are reported" do
    assert ["C15"] == duplicate_ids(["C15", "C15"])
  end

  test "a dangling prose reference is red until its heading is updated" do
    sources = %{
      "register" => "**C7 — current carve.**\n",
      "prose" => "The renamed carve is C8.\n"
    }

    assert [{"prose", "C8"}] == unresolved_references(sources, MapSet.new(["C7"]))

    updated_sources = Map.put(sources, "prose", "The renamed carve is C7.\n")
    assert [] == unresolved_references(updated_sources, MapSet.new(["C7"]))
  end

  test "task-scoped ids are derived from their task number" do
    assert [] == task_scoped_id_errors("**C-T314 — id allocation (task 314).**\n")

    assert [{"C-T314", "315"}] ==
             task_scoped_id_errors("**C-T314 — id allocation (task 315).**\n")
  end

  test "a heading that wraps across lines is still checked against its task number" do
    wrapped = "**C-T314 — a title long enough to wrap.\nOutcome: DIVERGE (task 999).**\n"

    assert [{"C-T314", "999"}] == task_scoped_id_errors(wrapped)

    assert [] ==
             task_scoped_id_errors("**C-T314 — a title long enough to wrap.\nOutcome: DIVERGE (task 314).**\n")
  end

  test "one task may register several carves via a letter suffix" do
    register = "**C-T277a — first carve (task 277).**\n**C-T277b — second carve (task 277).**\n"

    assert ["C-T277a", "C-T277b"] == register_ids(register)
    assert [] == duplicate_ids(register_ids(register))
    assert [] == task_scoped_id_errors(register)
    assert [] == unexpected_legacy_ids(register_ids(register))
  end

  test "a hand-allocated legacy-style id is rejected" do
    assert ["C40"] == unexpected_legacy_ids(["C7", "C40", "C-T314"])
  end

  test "the latest dated evidence status supersedes earlier verification prose" do
    sources = %{
      "alpaca.md" =>
        status_block(%{
          "carve_id" => "C-T428a",
          "date" => "2026-07-19",
          "semantic_source" => provider_source("Alpaca docs"),
          "observed_evidence" => nil,
          "compatibility_reference" => nil,
          "resolved_tier" => 2,
          "known_gap_reason" => "credentials unavailable"
        }) <>
          status_block(%{
            "carve_id" => "C-T428a",
            "date" => "2026-07-20",
            "semantic_source" => provider_source("Alpaca docs"),
            "observed_evidence" => observed_source("recorded 200 response"),
            "compatibility_reference" => %{"kind" => "ccxt", "reference" => "compatibility only"},
            "resolved_tier" => 1
          })
    }

    current = sources |> evidence_status_records() |> current_evidence_statuses() |> Map.fetch!("C-T428a")

    assert "2026-07-20" == current["date"]
    assert %{"kind" => "provider_owned"} = current["semantic_source"]
    assert %{"kind" => "recorded_venue"} = current["observed_evidence"]
    assert %{"kind" => "ccxt"} = current["compatibility_reference"]
    assert 1 == current["resolved_tier"]
  end

  test "tier 1 rejects docs alone, ledger status alone, and Bourse evidence" do
    records =
      evidence_status_records(%{
        "demo.md" =>
          status_block(tier_one_status("C-T1", provider_source("official docs"), nil)) <>
            status_block(
              tier_one_status(
                "C-T2",
                provider_source("official docs"),
                %{"kind" => "ledger_status", "reference" => "closed"}
              )
            ) <>
            status_block(
              tier_one_status(
                "C-T3",
                %{"kind" => "ccxt", "reference" => "CCXT source"},
                %{"kind" => "ccxt", "reference" => "CCXT fixture"}
              )
            )
      })

    errors = evidence_status_errors(records)

    assert Enum.any?(errors, &String.contains?(&1, "demo C-T1: tier 1 requires observed venue evidence"))
    assert Enum.any?(errors, &String.contains?(&1, "demo C-T2: tier 1 requires observed venue evidence"))
    assert Enum.any?(errors, &String.contains?(&1, "demo C-T3: tier 1 requires a provider-owned semantic source"))
    assert Enum.any?(errors, &String.contains?(&1, "demo C-T3: tier 1 requires observed venue evidence"))
  end

  test "recorded venue evidence at every tier names a registered frozen body" do
    for tier <- [1, 2, 3] do
      status =
        "C-T603"
        |> tier_one_status(provider_source("official docs"), %{
          "kind" => "recorded_venue",
          "reference" => "unregistered parser golden",
          "fixture" => "test/fixtures/responses/demo/missing.json"
        })
        |> Map.put("resolved_tier", tier)
        |> maybe_put_gap(tier)
        |> Map.merge(%{"_venue" => "demo", "_path" => "demo.md"})

      assert Enum.any?(
               evidence_status_entry_errors(status),
               &String.contains?(&1, "recorded_venue requires a registered response fixture")
             )
    end
  end

  test "provider-shaped evidence is explicit and valid only below tier 1" do
    for tier <- [2, 3] do
      status =
        "C-T603"
        |> tier_one_status(provider_source("official docs"), %{
          "kind" => "provider_shaped",
          "reference" => "provider-shaped parser row"
        })
        |> Map.put("resolved_tier", tier)
        |> maybe_put_gap(tier)
        |> Map.merge(%{"_venue" => "demo", "_path" => "demo.md"})

      assert [] == evidence_status_entry_errors(status)
    end
  end

  test "a closed-ledger contradiction names venue, carve id, and both tiers" do
    statuses = %{
      "C-T428a" => %{"resolved_tier" => 2, "_venue" => "alpaca"}
    }

    claims = [%{venue: "alpaca", carve_id: "C-T428a", tier: 1}]

    assert ["alpaca C-T428a: register tier 2 contradicts closed ledger tier 1"] ==
             ledger_tier_errors(claims, statuses)
  end

  test "outcome, tier, and verification vocabulary all require evidence statuses" do
    sources = %{
      "demo.md" => """
      **C-T901 — outcome claim (task 901). Outcome: CONFIRMED.**
      **C-T902 — tier claim (task 902).** This remains tier 2.
      **C-T903 — verification claim (task 903).**
      - *Verification:* documentation-anchored.
      **C-T904 — live result (task 904).** This is verified against the venue.
      """
    }

    assert [
             {"demo.md", "C-T901"},
             {"demo.md", "C-T902"},
             {"demo.md", "C-T903"},
             {"demo.md", "C-T904"}
           ] == prose_claim_status_errors(sources, %{})

    statuses = Map.new(~w(C-T901 C-T902 C-T903 C-T904), &{&1, %{}})
    assert [] == prose_claim_status_errors(sources, statuses)
  end

  defp register_ids(markdown) do
    ~r/^\*\*((?:[BC]\d+[a-z]?|C-T\d+[a-z]?))\s+—/m
    |> Regex.scan(markdown, capture: :all_but_first)
    |> List.flatten()
  end

  defp legacy_id?(id), do: String.match?(id, ~r/^[BC]\d+[a-z]?$/)

  defp unexpected_legacy_ids(ids) do
    ids
    |> Enum.filter(&legacy_id?/1)
    |> MapSet.new()
    |> MapSet.difference(@legacy_ids)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  # `s` lets a heading wrap across lines the way the legacy register entries already do;
  # without it a wrapped heading matches nothing and skips the derivation check silently.
  defp task_scoped_id_errors(markdown) do
    ~r/^\*\*(C-T(\d+)[a-z]?)\s+—(.*?)\*\*/ms
    |> Regex.scan(markdown, capture: :all_but_first)
    |> Enum.reject(fn [_id, task_id, heading] ->
      Regex.match?(~r/\btask\s+#{task_id}\b/i, heading)
    end)
    |> Enum.map(fn [id, _task_id, heading] ->
      [_, referenced_task_id] = Regex.run(~r/\btask\s+(\d+)\b/i, heading) || [nil, nil]
      {id, referenced_task_id}
    end)
  end

  defp read_sources(paths) do
    Map.new(paths, &{&1, File.read!(&1)})
  end

  defp read_register(paths) do
    Enum.map_join(paths, "\n", &File.read!/1)
  end

  defp evidence_status_records(sources) do
    Enum.flat_map(sources, fn {path, content} ->
      venue = Path.basename(path, ".md")

      ~r/<!-- carve-evidence-status\s*(\{.*?\})\s*-->/s
      |> Regex.scan(content, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(fn json ->
        json
        |> Jason.decode!()
        |> Map.put("_venue", venue)
        |> Map.put("_path", path)
      end)
    end)
  end

  defp current_evidence_statuses(records) do
    records
    |> Enum.group_by(&Map.get(&1, "carve_id"))
    |> Map.new(fn {carve_id, entries} ->
      {carve_id, Enum.max_by(entries, &Map.get(&1, "date", ""))}
    end)
  end

  defp evidence_status_errors(records) do
    duplicate_errors =
      records
      |> Enum.group_by(&{Map.get(&1, "carve_id"), Map.get(&1, "date")})
      |> Enum.flat_map(fn
        {{carve_id, date}, entries} when length(entries) > 1 ->
          ["#{carve_id}: duplicate evidence status date #{date}"]

        _entry ->
          []
      end)

    duplicate_errors ++ Enum.flat_map(records, &evidence_status_entry_errors/1)
  end

  defp evidence_status_entry_errors(status) do
    prefix = "#{status["_venue"]} #{status["carve_id"]}"

    missing_fields =
      @evidence_fields
      |> Enum.reject(&Map.has_key?(status, &1))
      |> Enum.map(&"#{prefix}: evidence status is missing #{&1}")

    date_errors =
      case Date.from_iso8601(status["date"] || "") do
        {:ok, _date} -> []
        {:error, _reason} -> ["#{prefix}: evidence status date must be ISO-8601"]
      end

    tier_errors =
      if status["resolved_tier"] in [1, 2, 3] do
        []
      else
        ["#{prefix}: resolved_tier must be 1, 2, or 3"]
      end

    gap_errors =
      if status["resolved_tier"] in [2, 3] and not nonempty?(status["known_gap_reason"]) do
        ["#{prefix}: tier #{status["resolved_tier"]} requires known_gap_reason"]
      else
        []
      end

    missing_fields ++
      date_errors ++
      tier_errors ++
      gap_errors ++ observed_evidence_errors(status, prefix) ++ tier_one_errors(status, prefix)
  end

  defp observed_evidence_errors(%{"observed_evidence" => nil}, _prefix), do: []

  defp observed_evidence_errors(%{"observed_evidence" => evidence} = status, prefix) when is_map(evidence) do
    kind = evidence["kind"]

    kind_errors =
      if kind in @observed_evidence_kinds and nonempty?(evidence["reference"]) and
           (not strict_recording_status?(status) or kind in @strict_observed_evidence_kinds) do
        []
      else
        ["#{prefix}: observed_evidence must use a supported kind with a non-empty reference"]
      end

    recording_errors =
      if strict_recording_status?(status) and kind == "recorded_venue" and
           not MapSet.member?(@registered_response_fixtures, evidence["fixture"]) do
        ["#{prefix}: recorded_venue requires a registered response fixture"]
      else
        []
      end

    kind_errors ++ recording_errors
  end

  defp observed_evidence_errors(_status, prefix), do: ["#{prefix}: observed_evidence must be an object or null"]

  defp strict_recording_status?(%{"carve_id" => carve_id}) do
    case Regex.run(~r/^C-T(\d+)/, carve_id, capture: :all_but_first) do
      [task] -> String.to_integer(task) >= @strict_recording_task
      nil -> false
    end
  end

  defp tier_one_errors(%{"resolved_tier" => 1} = status, prefix) do
    semantic_errors =
      if evidence_kind?(status["semantic_source"], "provider_owned") do
        []
      else
        ["#{prefix}: tier 1 requires a provider-owned semantic source"]
      end

    observed_errors =
      if observed_evidence?(status["observed_evidence"]) do
        []
      else
        ["#{prefix}: tier 1 requires observed venue evidence"]
      end

    semantic_errors ++ observed_errors
  end

  defp tier_one_errors(_status, _prefix), do: []

  defp evidence_kind?(%{"kind" => kind, "reference" => reference}, kind), do: nonempty?(reference)
  defp evidence_kind?(_evidence, _kind), do: false

  defp observed_evidence?(%{"kind" => kind, "reference" => reference}) do
    kind in ["live_venue", "recorded_venue"] and nonempty?(reference)
  end

  defp observed_evidence?(_evidence), do: false

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp closed_ledger_claims(markdown) do
    closed = markdown |> String.split("\n## Closed\n", parts: 2) |> List.last()

    ~r/^###\s+([^\n]+)$/m
    |> Regex.scan(closed, capture: :all_but_first)
    |> List.flatten()
    |> Enum.flat_map(fn heading ->
      venue = heading |> String.split(" —", parts: 2) |> hd()
      Enum.map(ledger_heading_ids(heading), &%{venue: venue, carve_id: &1, tier: 1})
    end)
  end

  defp ledger_heading_ids(heading) do
    expanded =
      ~r/\b(C-T\d+)([a-z])((?:\/[a-z])+)\b/
      |> Regex.scan(heading, capture: :all_but_first)
      |> Enum.flat_map(fn [base, first, rest] ->
        Enum.map([first | String.split(rest, "/", trim: true)], &(base <> &1))
      end)

    heading
    |> reference_ids()
    |> Kernel.++(expanded)
    |> Enum.uniq()
  end

  defp ledger_tier_errors(claims, statuses) do
    Enum.flat_map(claims, fn claim ->
      case Map.get(statuses, claim.carve_id) do
        nil ->
          ["#{claim.venue} #{claim.carve_id}: closed ledger tier #{claim.tier} has no register status"]

        %{"resolved_tier" => tier} when tier != claim.tier ->
          [
            "#{claim.venue} #{claim.carve_id}: register tier #{tier} contradicts closed ledger tier #{claim.tier}"
          ]

        _status ->
          []
      end
    end)
  end

  defp prose_claim_status_errors(sources, statuses) do
    Enum.flat_map(sources, fn {path, content} ->
      ~r/^\*\*((?:[BC]\d+[a-z]?|C-T\d+[a-z]?))\s+—.*?(?=^\*\*(?:[BC]\d+[a-z]?|C-T\d+[a-z]?)\s+—|^##\s|\z)/ms
      |> Regex.scan(content)
      |> Enum.flat_map(&prose_claim_status_error(&1, path, statuses))
    end)
  end

  defp prose_claim_status_error([section, carve_id], path, statuses) do
    if prose_evidence_claim?(section) and not Map.has_key?(statuses, carve_id) do
      [{path, carve_id}]
    else
      []
    end
  end

  defp prose_evidence_claim?(section) do
    Regex.match?(
      ~r/(?:\*Verification:\*|\bVERIF(?:IED|ICATION)\b|\bOutcome\s*:|\btier[\s-]*[123]\b|\b(?:CONFIRM(?:ED)?|DIVERGE(?:NCE|D)?|ALIGNED|DEFERRED)\b)/i,
      section
    )
  end

  defp completeness_claim_errors(sources) do
    Enum.flat_map(sources, fn {path, content} ->
      claim = Map.fetch!(@completeness_claims, Path.basename(path))
      if String.contains?(content, claim), do: [], else: [{path, claim}]
    end)
  end

  defp oracle_labels(sources) do
    Enum.flat_map(sources, fn {path, content} ->
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _number} -> Regex.match?(~r/\bOracle(?:\s*\([^)]*\))?:/, line) end)
      |> Enum.map(fn {_line, number} -> {path, number} end)
    end)
  end

  defp status_block(status), do: "<!-- carve-evidence-status\n#{Jason.encode!(status)}\n-->\n"

  defp tier_one_status(carve_id, semantic_source, observed_evidence) do
    %{
      "carve_id" => carve_id,
      "date" => "2026-07-22",
      "semantic_source" => semantic_source,
      "observed_evidence" => observed_evidence,
      "compatibility_reference" => nil,
      "resolved_tier" => 1
    }
  end

  defp provider_source(reference), do: %{"kind" => "provider_owned", "reference" => reference}
  defp observed_source(reference), do: %{"kind" => "recorded_venue", "reference" => reference}

  defp maybe_put_gap(status, 1), do: status
  defp maybe_put_gap(status, tier), do: Map.put(status, "known_gap_reason", "tier #{tier} test gap")

  defp unresolved_references(sources, registered_ids) do
    sources
    |> Enum.flat_map(fn {path, content} ->
      content
      |> reference_ids()
      |> Enum.reject(&MapSet.member?(registered_ids, &1))
      |> Enum.map(&{path, &1})
    end)
    |> Enum.sort()
  end

  defp reference_ids(content) do
    ~r/\b(?:[BC]\d+[a-z]?|C-T\d+[a-z]?)\b/
    |> Regex.scan(content)
    |> List.flatten()
  end

  defp duplicate_ids(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end
end
