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
    manifests = AuthorityCorpus.load!(@root)

    for manifest <- manifests, artifact <- manifest["artifacts"] do
      assert artifact["freshness"]["status"] in ~w(reviewed_current initial_baseline pinned_snapshot known_stale drift_detected)

      assert artifact["expressiveness"]["level"] in ~w(typed_openapi typed_asyncapi untyped_postman documentation_index prose_documentation source_archive)

      surfaces = Enum.map(artifact["scope"], & &1["surface"])
      refute "current_rest" in surfaces and "upcoming_rest" in surfaces
      refute "current_websocket" in surfaces and "upcoming_websocket" in surfaces
      assert artifact["authority"]["classification"] == "provider_owned"

      if artifact["freshness"]["status"] == "known_stale" or
           Enum.any?(artifact["scope"], &(&1["coverage"] == "index_only")) do
        refute artifact["authority"]["semantic_authority"]
      end
    end

    refute Enum.all?(manifests, fn manifest ->
             Enum.all?(manifest["artifacts"], & &1["authority"]["semantic_authority"])
           end)
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

    prior_report =
      Bourse.JsonDocument.decode_file!("priv/authority/deribit/current-rest-drift-2026-08-10.json")

    report =
      Bourse.JsonDocument.decode_file!("priv/authority/deribit/current-rest-drift-2026-08-18.json")

    assert prior_report["prior"]["sha256"] ==
             "70ba4617642d18aaff2bbcb7127bec499c4ef3ba34b6f5b12cb9cbdadbcffd2d"

    assert report["prior"]["sha256"] == prior_report["current"]["sha256"]
    assert report["current"]["sha256"] == artifact["sha256"]
    assert report["current"]["bytes"] == artifact["bytes"]
    assert report["operation_delta"]["count"] == 4

    assert report["operation_delta"]["added"] == [
             "GET /api/v2/private/get_lsp_participant_config",
             "GET /api/v2/private/get_lsp_participants",
             "GET /api/v2/private/get_lsp_participants_usage",
             "GET /api/v2/private/get_lsp_usage"
           ]

    assert report["operation_delta"]["removed"] == []
    assert report["operation_delta"]["upcoming_path_set_comparison"] == "exact_match_182_paths"
    assert report["pin_key_decision"]["decision"] == "retain_content_sha256_with_version_and_etag_upstream_pin"
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

  test "known-stale and index-only artifacts cannot claim semantic authority" do
    for {field_path, value} <- [
          {["freshness", "status"], "known_stale"},
          {["scope", Access.at(0), "coverage"], "index_only"}
        ] do
      root =
        write_corpus(fn
          "binance", manifest ->
            manifest
            |> put_in(["artifacts", Access.at(0)] ++ field_path, value)
            |> put_in(["artifacts", Access.at(0), "authority", "semantic_authority"], true)

          _venue, manifest ->
            manifest
        end)

      assert_raise Mix.Error, ~r/cannot claim semantic authority/, fn ->
        AuthorityCorpus.load!(root)
      end
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

  test "typed contract drift fails based on expressiveness even when its URL looks like prose" do
    artifact =
      fixture_artifact()
      |> put_in(["drift", "url"], "https://example.test/rendered-docs-page")
      |> put_in(["expressiveness", "level"], "typed_openapi")
      |> put_in(["freshness", "status"], "drift_detected")

    error =
      assert_raise Mix.Error, fn ->
        check_artifact!(artifact, fetcher: fn _url -> "drifted-upstream-content" end)
      end

    assert error.message =~ "fixture: typed contract upstream drift"
    assert error.message =~ artifact["sha256"]
    assert error.message =~ AuthorityCorpus.sha256("drifted-upstream-content")
  end

  test "acknowledged prose drift warns, emits a durable report line, and exits green" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    artifact =
      fixture_artifact()
      |> put_in(["drift", "url"], "https://example.test/contract.json")
      |> Map.put("fetch_url", "https://example.test/contract.json")
      |> put_in(["freshness", "status"], "drift_detected")
      |> put_in(["freshness", "checked_at"], "2026-08-10")

    assert :ok =
             check_artifact!(artifact,
               fetcher: fn _url -> "drifted-upstream-content" end,
               today: ~D[2026-08-10]
             )

    assert_receive {:mix_shell, :error, [warning]}
    assert warning =~ "WARNING: binance/fixture prose/docs upstream drift"

    assert_receive {:mix_shell, :info, [report_line]}
    assert report_line =~ "AUTHORITY_DRIFT"
    assert report_line =~ "venue=binance"
    assert report_line =~ "artifact=fixture"
    assert report_line =~ "class=prose_docs"
    assert report_line =~ "status=acknowledged"
    assert report_line =~ "checked_at=2026-08-10"
  end

  test "unacknowledged prose drift fails with an actionable manifest update" do
    error =
      assert_raise Mix.Error, fn ->
        check_artifact!(fixture_artifact(),
          fetcher: fn _url -> "drifted-upstream-content" end,
          today: ~D[2026-08-10]
        )
      end

    assert error.message =~ "unacknowledged prose/docs upstream drift"
    assert error.message =~ "freshness.status=drift_detected"
    assert error.message =~ "freshness.checked_at"
  end

  test "a prose drift acknowledgment older than the bounded window fails" do
    artifact =
      fixture_artifact()
      |> put_in(["freshness", "status"], "drift_detected")
      |> put_in(["freshness", "checked_at"], "2026-07-10")

    error =
      assert_raise Mix.Error, fn ->
        check_artifact!(artifact,
          fetcher: fn _url -> "drifted-upstream-content" end,
          today: ~D[2026-08-10]
        )
      end

    assert error.message =~ "stale prose/docs drift acknowledgment"
    assert error.message =~ "31 days"
    assert error.message =~ "30-day limit"
  end

  test "git-head drift retains typed-contract failure semantics" do
    artifact =
      fixture_artifact()
      |> Map.put("drift", %{"mode" => "git_head", "repository_url" => "https://example.test/docs.git"})
      |> put_in(["expressiveness", "level"], "typed_asyncapi")

    error =
      assert_raise Mix.Error, fn ->
        check_artifact!(artifact, git_head: fn _url -> String.duplicate("a", 40) end)
      end

    assert error.message =~ "typed contract upstream drift"
    assert error.message =~ artifact["upstream_pin"]["value"]
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

  test "a present surface digest must name the same pin as the manifest" do
    root = write_corpus(fn _venue, manifest -> manifest end)
    digest_dir = Path.join([root, "binance", "surface-digests"])
    File.mkdir_p!(digest_dir)

    File.write!(
      Path.join(digest_dir, "fixture.json"),
      Jason.encode!(%{
        "schema_version" => 1,
        "artifact_id" => "fixture",
        "source" => %{"sha256" => String.duplicate("a", 64), "bytes" => 1},
        "key_sets" => %{"channel_keys" => [], "path_keys" => [], "operation_keys" => []}
      })
    )

    assert_raise Mix.Error, ~r/surface digest source sha256 mismatch/, fn ->
      AuthorityCorpus.load!(root)
    end
  end

  test "reference-only artifacts remain valid when no surface digest is retained" do
    root = write_corpus(fn _venue, manifest -> manifest end)
    assert [%{"venue" => "alpaca"} | _] = AuthorityCorpus.load!(root)
    refute File.exists?(Path.join([root, "binance", "surface-digests", "fixture.json"]))
  end

  test "a surface digest that names the manifest pin is accepted" do
    root = write_corpus(fn _venue, manifest -> manifest end)
    artifact = List.first(fixture_manifest("binance")["artifacts"])
    digest_dir = Path.join([root, "binance", "surface-digests"])
    File.mkdir_p!(digest_dir)

    File.write!(
      Path.join(digest_dir, "fixture.json"),
      Jason.encode!(%{
        "schema_version" => 1,
        "artifact_id" => "fixture",
        "source" => %{"sha256" => artifact["sha256"], "bytes" => artifact["bytes"]},
        "key_sets" => %{"channel_keys" => [], "path_keys" => [], "operation_keys" => []}
      })
    )

    assert Enum.any?(AuthorityCorpus.load!(root), &(&1["venue"] == "binance"))
  end

  test "a present surface digest must hash its key sets consistently" do
    root = write_corpus(fn _venue, manifest -> manifest end)
    artifact = List.first(fixture_manifest("binance")["artifacts"])
    digest_dir = Path.join([root, "binance", "surface-digests"])
    File.mkdir_p!(digest_dir)

    File.write!(
      Path.join(digest_dir, "fixture.json"),
      Jason.encode!(%{
        "schema_version" => 1,
        "artifact_id" => "fixture",
        "source" => %{"sha256" => artifact["sha256"], "bytes" => artifact["bytes"]},
        "key_sets" => %{"channel_keys" => ["user.lsp"], "path_keys" => [], "operation_keys" => []},
        "key_set_sha256" => %{
          "channel_keys" => String.duplicate("0", 64),
          "path_keys" => nil,
          "operation_keys" => nil
        }
      })
    )

    assert_raise Mix.Error, ~r/surface digest channel_keys sha256 mismatch/, fn ->
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

  test "fetch materializes verified pinned bytes outside the authority tree" do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "authority-root-#{unique}")
    destination = Path.join(System.tmp_dir!(), "authority-fetch-#{unique}")
    source = Path.join(System.tmp_dir!(), "authority-source-#{unique}.txt")
    contents = "verified authority bytes"

    File.mkdir_p!(root)
    File.write!(source, contents)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(destination)
      File.rm(source)
    end)

    artifact =
      Map.merge(fixture_artifact(), %{
        "fetch_url" => "file://#{source}",
        "sha256" => AuthorityCorpus.sha256(contents),
        "bytes" => byte_size(contents)
      })

    manifest = %{"venue" => "binance", "artifacts" => [artifact]}

    assert :ok = AuthorityCheck.fetch!([manifest], destination, root)
    assert File.read!(Path.join([destination, "binance", artifact["filename"]])) == contents
  end

  test "task rejects positional arguments and conflicting network modes" do
    assert_raise Mix.Error, ~r/unexpected arguments: extra/, fn ->
      AuthorityCheck.run(["extra"])
    end

    assert_raise Mix.Error, ~r/--online and --fetch are mutually exclusive/, fn ->
      AuthorityCheck.run(["--online", "--fetch", "/tmp/authority"])
    end
  end

  defp check_artifact!(artifact, opts) do
    AuthorityCheck.check_upstream!([%{"venue" => "binance", "artifacts" => [artifact]}], opts)
  end

  defp fixture_artifact do
    List.first(fixture_manifest("binance")["artifacts"])
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
