defmodule Mix.Tasks.Ccxt.ErrorAuthorityTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ccxt.AuthorityCorpus
  alias Mix.Tasks.Ccxt.ErrorAuthority
  alias Mix.Tasks.Ccxt.ErrorAuthorityCorpus

  @authority_root "priv/venues"
  @spec_root "priv/venues"

  test "every authored exact mapping is present in its venue's pinned enumeration" do
    reports = ErrorAuthorityCorpus.validate!()

    assert Enum.map(reports, & &1.venue) == AuthorityCorpus.error_enumeration_venues()

    for report <- reports do
      assert report.mapped_count <= report.documented_count
      assert report.documented_not_mapped != []
      assert report.disposition == "exchange_error"
    end
  end

  test "report surfaces dropped, retired, and provider-only identifiers" do
    reports = Map.new(ErrorAuthorityCorpus.validate!(), &{&1.venue, &1})

    assert reports["binance"].dropped_non_authoritative != []
    assert reports["binanceusdm"].dropped_non_authoritative != []
    assert "10018" in reports["bybit"].retired
    assert reports["deribit"].dropped_non_authoritative != []
    assert reports["derive"].dropped_non_authoritative != []
    assert reports["okx"].dropped_non_authoritative != []
    assert reports["hyperliquid"].documented_not_mapped != []
  end

  test "an unknown authored code fails with the venue and code" do
    spec_root = copy_specs()
    path = Path.join([spec_root, "binance", "authored", "spec.json"])
    spec = path |> File.read!() |> Jason.decode!()

    spec =
      update_in(spec, ["errors", "handle_errors", "exceptions", "exact"], fn exact ->
        Map.put(exact, "-999999", "__function:BadRequest")
      end)

    File.write!(path, Jason.encode!(spec))

    assert_raise Mix.Error, ~r/binance: authored error_codes entry "-999999".*official enumeration/, fn ->
      ErrorAuthorityCorpus.validate!(@authority_root, spec_root)
    end
  end

  test "complete owned specs do not inherit reference-only error mappings" do
    reports = Map.new(ErrorAuthorityCorpus.validate!(), &{&1.venue, &1})
    owned = [@spec_root, "binancecoinm", "authored", "spec.json"] |> Path.join() |> File.read!() |> Jason.decode!()
    exact = get_in(owned, ["errors", "handle_errors", "exceptions", "exact"])

    assert reports["binancecoinm"].mapped_count == map_size(exact)
    refute Map.has_key?(exact, "-20121")
  end

  test "the task emits one adjudication summary per venue" do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    assert :ok = ErrorAuthority.run([])

    for venue <- AuthorityCorpus.error_enumeration_venues() do
      assert_receive {:mix_shell, :info, [message]}
      assert message =~ venue
      assert message =~ "provider-only -> exchange_error"
      assert message =~ "maintenance="
    end
  end

  # Task 451: Lighter is first-class but its provider publishes no error-code
  # enumeration, so it cannot be graded against a pinned document. The exemption is
  # governed here rather than hidden: it must stay minimal, must state a reason, and
  # every code an exempt venue authors must be pinned by a live tagged test instead.
  test "error-enumeration exemptions are justified and every non-exempt venue has a corpus" do
    exemptions = AuthorityCorpus.error_enumeration_exemptions()

    assert Map.keys(exemptions) == ["lighter"],
           "the error-enumeration exemption set must only shrink; adding one requires live-evidence justification"

    for {venue, reason} <- exemptions do
      assert venue in AuthorityCorpus.venues()
      assert is_binary(reason) and String.length(reason) > 40

      refute File.exists?(Path.join([@authority_root, venue, "authority", "errors.json"])),
             "#{venue} is exempt but ships an enumeration corpus — remove the exemption instead"

      for {code, _class} <- exempt_exact_mappings(venue) do
        assert Enum.any?(live_evidence_sources(reason), &(&1 =~ code)),
               "#{venue} authors error code #{code} with no pinned live evidence"
      end
    end

    for venue <- AuthorityCorpus.error_enumeration_venues() do
      assert File.exists?(Path.join([@authority_root, venue, "authority", "errors.json"])),
             "#{venue} is graded against an enumeration but ships no corpus"
    end
  end

  defp exempt_exact_mappings(venue) do
    [@spec_root, venue, "authored", "spec.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["errors", "handle_errors", "exceptions", "exact"]) || %{}
  end

  # Digit separators are stripped so an assertion written as the Elixir literal
  # `20_001` still counts as evidence for the authored `"20001"` key.
  defp live_evidence_sources(reason) do
    ~r/\S+_test\.exs/
    |> Regex.scan(reason)
    |> Enum.map(fn [path] -> path |> File.read!() |> String.replace(~r/(?<=\d)_(?=\d)/, "") end)
  end

  test "maintenance adjudications require documented OnMaintenance mappings when claimed" do
    reports = Map.new(ErrorAuthorityCorpus.validate!(), &{&1.venue, &1})

    assert reports["binance"].maintenance_status == "mapped"
    assert "-1016" in reports["binance"].maintenance_identifiers
    assert reports["binancecoinm"].maintenance_status == "mapped"
    assert reports["binanceusdm"].maintenance_status == "mapped"
    assert reports["bybit"].maintenance_status == "mapped"
    assert "180023" in reports["bybit"].maintenance_identifiers
    assert reports["okx"].maintenance_status == "confirmed_mapped"
    assert reports["deribit"].maintenance_status == "confirmed_mapped"
    assert reports["derive"].maintenance_status == "no_documented_maintenance_code"
    assert reports["hyperliquid"].maintenance_status == "no_documented_maintenance_code"
  end

  defp copy_specs do
    root = Path.join(System.tmp_dir!(), "error-authority-specs-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    for venue <- AuthorityCorpus.venues() do
      File.mkdir_p!(Path.join([root, venue, "authored"]))

      File.cp!(
        Path.join([@spec_root, venue, "authored", "spec.json"]),
        Path.join([root, venue, "authored", "spec.json"])
      )
    end

    root
  end
end
