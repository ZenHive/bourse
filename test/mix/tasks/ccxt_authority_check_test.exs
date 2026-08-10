defmodule Mix.Tasks.Ccxt.AuthorityCheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ccxt.AuthorityCheck
  alias Mix.Tasks.Ccxt.AuthorityCorpus

  @root "priv/authority"

  test "committed corpus covers every first-class venue with reference-only licensing" do
    manifests = AuthorityCorpus.load!(@root)
    venue_directories = @root |> File.ls!() |> Enum.filter(&File.dir?(Path.join(@root, &1))) |> Enum.sort()

    assert Enum.map(manifests, & &1["venue"]) == AuthorityCorpus.venues()
    assert venue_directories == Enum.sort(AuthorityCorpus.venues())

    for manifest <- manifests,
        artifact <- manifest["artifacts"] do
      assert artifact["storage"] == "reference_only"
      assert artifact["path"] == nil
      assert artifact["license"]["handling"] == "reference_only"
      assert artifact["upstream_pin"]["value"] != ""
    end
  end

  test "offline task validates manifests without fetching upstream" do
    assert :ok = AuthorityCheck.run([])
  end

  test "offline success is explicitly not a remote freshness result" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    assert :ok = AuthorityCheck.run([])
    assert_receive {:mix_shell, :info, [message]}
    assert message =~ "offline validation"
    refute message =~ "upstream unchanged"
  end

  test "artifacts use the governed role vocabulary and keep versioned surfaces separate" do
    for manifest <- AuthorityCorpus.load!(@root), artifact <- manifest["artifacts"] do
      assert artifact["freshness"]["status"] in ~w(reviewed_current initial_baseline pinned_snapshot known_stale drift_detected)

      assert artifact["expressiveness"]["level"] in ~w(typed_openapi typed_asyncapi untyped_postman documentation_index prose_documentation source_archive)

      surfaces = Enum.map(artifact["scope"], & &1["surface"])
      refute "current_rest" in surfaces and "upcoming_rest" in surfaces
      refute "current_websocket" in surfaces and "upcoming_websocket" in surfaces
      assert artifact["authority"]["classification"] == "provider_owned"
    end
  end

  test "Deribit versioned contracts have distinct baselines and runtime denominators" do
    manifest = Enum.find(AuthorityCorpus.load!(@root), &(&1["venue"] == "deribit"))

    by_surface =
      Enum.reduce(manifest["artifacts"], %{}, fn artifact, acc ->
        Enum.reduce(artifact["scope"], acc, fn artifact_scope, scopes ->
          Map.update(scopes, artifact_scope["surface"], [artifact["id"]], &[artifact["id"] | &1])
        end)
      end)

    assert "api-openapi" in by_surface["current_rest"]
    assert by_surface["upcoming_rest"] == ["upcoming-openapi"]
    assert by_surface["current_websocket"] == ["current-asyncapi"]
    assert by_surface["upcoming_websocket"] == ["upcoming-asyncapi"]
    assert by_surface["documentation_index"] == ["docs-index"]
    refute "upcoming-openapi" in by_surface["current_rest"]
  end

  test "Deribit current REST refresh is bound to its semantic diff report" do
    manifest = Enum.find(AuthorityCorpus.load!(@root), &(&1["venue"] == "deribit"))
    artifact = Enum.find(manifest["artifacts"], &(&1["id"] == "api-openapi"))

    report =
      Bourse.JsonDocument.decode_file!("priv/authority/deribit/current-rest-drift-2026-08-10.json")

    assert report["prior"]["sha256"] ==
             "70ba4617642d18aaff2bbcb7127bec499c4ef3ba34b6f5b12cb9cbdadbcffd2d"

    assert report["current"]["sha256"] == artifact["sha256"]
    assert report["current"]["bytes"] == artifact["bytes"]
    assert report["operation_delta"]["count"] == 0
    assert report["operation_delta"]["current_runtime_denominator_change"] == "not_detected"
    assert report["operation_delta"]["authored_relation_counts"]["change_from_2026_08_04_measurement"] == 0
    assert report["structural_deltas"] != []
  end

  test "partial or untyped sources cannot declare themselves completeness gates" do
    root =
      write_corpus(fn
        "binance", manifest ->
          manifest
          |> put_in(["artifacts", Access.at(0), "authority", "completeness_gate"], true)
          |> put_in(["artifacts", Access.at(0), "scope", Access.at(0), "coverage"], "partial")

        _venue, manifest ->
          manifest
      end)

    assert_raise Mix.Error, ~r/cannot be a completeness gate/, fn ->
      AuthorityCorpus.load!(root)
    end
  end

  test "unsupported artifact roles fail loudly" do
    root =
      write_corpus(fn
        "binance", manifest ->
          put_in(manifest, ["artifacts", Access.at(0), "scope", Access.at(0), "surface"], "future_rest")

        _venue, manifest ->
          manifest
      end)

    assert_raise Mix.Error, ~r/unsupported contract surface "future_rest"/, fn ->
      AuthorityCorpus.load!(root)
    end
  end

  test "an upstream change reports as drift for every venue artifact, naming expected vs actual pin" do
    drifted = "drifted-upstream-content"
    drifted_head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    for manifest <- AuthorityCorpus.load!(@root),
        artifact <- manifest["artifacts"] do
      error =
        assert_raise Mix.Error, fn ->
          AuthorityCheck.check_upstream!([Map.put(manifest, "artifacts", [artifact])],
            fetcher: fn _url -> drifted end,
            git_head: fn _url -> drifted_head end
          )
        end

      assert error.message =~ "#{artifact["id"]}: upstream drift"

      case artifact["drift"]["mode"] do
        "sha256" ->
          assert error.message =~ artifact["sha256"]
          assert error.message =~ AuthorityCorpus.sha256(drifted)

        "git_head" ->
          assert error.message =~ artifact["upstream_pin"]["value"]
          assert error.message =~ drifted_head
      end
    end
  end

  test "a corrupted pinned fetch reports as manifest verification failure, not drift" do
    root = write_corpus(fn _venue, manifest -> manifest end)
    [manifest | _] = AuthorityCorpus.load!(root)
    [artifact] = manifest["artifacts"]

    # The fixture's mutable drift target differs from its pinned fetch target:
    # serve pin-matching bytes on the drift URL and corrupted bytes on the pin.
    drift_url = artifact["drift"]["url"]
    refute artifact["fetch_url"] == drift_url

    error =
      assert_raise Mix.Error, fn ->
        AuthorityCheck.check_upstream!([manifest],
          fetcher: fn
            ^drift_url -> "authority"
            _pinned_url -> "corrupted"
          end
        )
      end

    assert error.message =~ "differs from manifest"
    refute error.message =~ "upstream drift"
  end

  test "matching upstream and pinned bytes pass the stubbed upstream check" do
    root = write_corpus(fn _venue, manifest -> manifest end)
    manifests = AuthorityCorpus.load!(root)

    assert :ok = AuthorityCheck.check_upstream!(manifests, fetcher: fn _url -> "authority" end)
  end

  test "every carve register cites its venue authority manifest" do
    for venue <- AuthorityCorpus.venues() do
      path = "docs/authored-spec-carves/#{venue}.md"
      assert File.read!(path) =~ "priv/authority/#{venue}/manifest.json"
    end
  end

  test "reference-only artifacts cannot point at committed content" do
    root =
      write_corpus(fn
        "binance", manifest -> put_in(manifest, ["artifacts", Access.at(0), "path"], "artifact.txt")
        _venue, manifest -> manifest
      end)

    assert_raise Mix.Error, ~r/reference-only artifact must not have a vendored path/, fn ->
      AuthorityCorpus.load!(root)
    end
  end

  test "vendored artifacts require explicit redistribution permission" do
    root =
      write_corpus(fn
        "binance", manifest ->
          manifest
          |> put_in(["artifacts", Access.at(0), "storage"], "vendored")
          |> put_in(["artifacts", Access.at(0), "path"], "artifact.txt")

        _venue, manifest ->
          manifest
      end)

    assert_raise Mix.Error, ~r/vendored content needs explicit permission/, fn ->
      AuthorityCorpus.load!(root)
    end
  end

  test "vendored artifact bytes must match the manifest" do
    expected = "expected"

    root =
      write_corpus(fn
        "binance", manifest ->
          artifact =
            manifest["artifacts"]
            |> List.first()
            |> Map.merge(%{
              "storage" => "vendored",
              "path" => "artifact.txt",
              "bytes" => byte_size(expected),
              "sha256" => AuthorityCorpus.sha256(expected),
              "license" => %{
                "status" => "permitted",
                "license" => "MIT",
                "evidence_url" => "https://example.test/LICENSE",
                "handling" => "vendored",
                "reason" => "Synthetic fixture"
              }
            })

          put_in(manifest, ["artifacts"], [artifact])

        _venue, manifest ->
          manifest
      end)

    File.write!(Path.join([root, "binance", "artifact.txt"]), "expacted")

    assert_raise Mix.Error, ~r/SHA-256 differs from manifest/, fn ->
      AuthorityCorpus.load!(root)
    end
  end

  test "fetch refuses to materialize artifacts inside the authority tree" do
    root = write_corpus(fn _venue, manifest -> manifest end)
    destination = Path.join(root, "download")

    assert_raise Mix.Error, ~r/--fetch destination must be outside/, fn ->
      AuthorityCheck.run(["--root", root, "--fetch", destination])
    end
  end

  test "fetch refuses the authority root itself" do
    root = write_corpus(fn _venue, manifest -> manifest end)

    assert_raise Mix.Error, ~r/--fetch destination must be outside/, fn ->
      AuthorityCheck.ensure_external_destination!(root, root)
    end
  end

  test "fetch accepts destinations outside the authority tree" do
    root = write_corpus(fn _venue, manifest -> manifest end)

    for destination <- [
          Path.join(System.tmp_dir!(), "ccxt-authority-out"),
          # A sibling whose path merely shares the root's prefix is not inside it.
          root <> "-out",
          "/tmp/ccxt-authority"
        ] do
      assert :ok = AuthorityCheck.ensure_external_destination!(destination, root)
    end
  end

  defp write_corpus(transform) do
    root = Path.join(System.tmp_dir!(), "authority-corpus-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    for venue <- AuthorityCorpus.venues() do
      directory = Path.join(root, venue)
      File.mkdir_p!(directory)

      manifest = transform.(venue, fixture_manifest(venue))
      File.write!(Path.join(directory, "manifest.json"), Jason.encode!(manifest))
    end

    root
  end

  defp fixture_manifest(venue) do
    contents = "authority"

    %{
      "schema_version" => 2,
      "venue" => venue,
      "official_docs_url" => "https://example.test/#{venue}",
      "selection_reason" => "Synthetic test manifest",
      "fetch_script" => "scripts/fetch_authority.sh",
      "artifacts" => [
        %{
          "id" => "fixture",
          "kind" => "text",
          "source_url" => "https://example.test/source",
          "fetch_url" => "https://example.test/fetch",
          "filename" => "fixture.txt",
          "retrieved_at" => "2026-07-22",
          "upstream_pin" => %{"type" => "etag", "value" => "fixture-pin"},
          "sha256" => AuthorityCorpus.sha256(contents),
          "bytes" => byte_size(contents),
          "storage" => "reference_only",
          "path" => nil,
          "license" => %{
            "status" => "unclear",
            "license" => "Unspecified",
            "evidence_url" => "https://example.test/terms",
            "handling" => "reference_only",
            "reason" => "Synthetic fixture"
          },
          "drift" => %{"mode" => "sha256", "url" => "https://example.test/source"},
          "freshness" => %{
            "status" => "initial_baseline",
            "checked_at" => "2026-08-10",
            "mutable" => true,
            "notes" => "Synthetic current baseline"
          },
          "expressiveness" => %{
            "level" => "prose_documentation",
            "limitations" => ["Synthetic fixture is not a typed contract"]
          },
          "scope" => [
            %{
              "surface" => "current_rest",
              "coverage" => "partial",
              "limitations" => ["Synthetic fixture covers one endpoint family"]
            }
          ],
          "authority" => %{
            "classification" => "provider_owned",
            "semantic_authority" => true,
            "completeness_gate" => false
          }
        }
      ],
      "rejected_candidates" => []
    }
  end
end
