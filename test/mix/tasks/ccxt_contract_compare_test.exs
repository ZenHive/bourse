defmodule Mix.Tasks.Ccxt.ContractCompareTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ccxt.AuthorityCorpus
  alias Mix.Tasks.Ccxt.ContractComparator
  alias Mix.Tasks.Ccxt.ContractCompare
  alias Mix.Tasks.Ccxt.ContractSource

  @authority_root "priv/authority"

  test "OpenAPI JSON captures supplied facts and keeps omitted security unknown" do
    result = ContractSource.parse!(artifact("openapi-json"), Jason.encode!(openapi_document()))
    create = Enum.find(result.operations, &(&1["method"] == "POST"))
    status = Enum.find(result.operations, &(&1["method"] == "GET"))

    assert create["key"] == "POST /api/v1/orders/{id}"
    assert create["authentication"] == known(%{"required" => true, "schemes" => ["apiKey"]})
    assert create["parameters"]["status"] == "known"
    assert Enum.any?(create["parameters"]["value"], &(&1["name"] == "id"))
    assert create["response_schemas"]["status"] == "known"
    assert create["examples"]["status"] == "known"
    assert status["authentication"] == ContractSource.unknown()
    assert result.metrics["path_count"] == 2
    assert "Provider examples are documentation, not observed-reality evidence." in result.limitations
  end

  test "OpenAPI YAML normalizes to the same deterministic operation inventory" do
    yaml = """
    openapi: 3.0.0
    servers:
      - url: https://provider.example/api/v1
    security:
      - apiKey: []
    paths:
      /orders/{id}:
        post:
          parameters:
            - name: id
              in: path
              required: true
              schema:
                type: string
          responses:
            "200":
              content:
                application/json:
                  schema:
                    type: object
    """

    result = ContractSource.parse!(artifact("openapi-yaml"), yaml)

    assert [%{"key" => "POST /api/v1/orders/{id}"} = operation] = result.operations
    assert operation["parameters"]["value"] |> hd() |> Map.fetch!("type") == known("string")
    assert result.operations == Enum.sort_by(result.operations, & &1["key"])
  end

  test "Postman preserves untyped request facts and inherited authentication" do
    document = %{
      "auth" => %{"type" => "apikey"},
      "item" => [
        %{
          "name" => "folder",
          "item" => [
            %{
              "name" => "create",
              "request" => %{
                "method" => "POST",
                "url" => %{
                  "path" => ["v1", "orders", ":id"],
                  "query" => [%{"key" => "limit", "value" => "10"}]
                },
                "body" => %{"raw" => ~s({"side":"buy"})}
              },
              "response" => [%{"code" => 200, "body" => ~s({"id":"1"})}]
            }
          ]
        }
      ]
    }

    result = ContractSource.parse!(artifact("postman-collection"), Jason.encode!(document))
    [operation] = result.operations

    assert operation["key"] == "POST /v1/orders/{id}"
    assert operation["authentication"] == known(%{"required" => true, "schemes" => ["apikey"]})
    assert operation["parameters"]["value"] |> hd() |> Map.fetch!("type") == ContractSource.unknown()
    assert operation["response_schemas"] == ContractSource.unknown()
    assert length(operation["examples"]["value"]) == 2
    assert Enum.any?(result.limitations, &(&1 =~ "untyped"))
    assert Enum.any?(result.limitations, &(&1 =~ "not paired live observations"))
  end

  test "AsyncAPI preserves send/receive message-reference inversion" do
    document = %{
      "asyncapi" => "3.0.0",
      "channels" => %{
        "ticker.(instrument)" => %{
          "parameters" => %{"instrument" => %{"schema" => %{"type" => "string"}}},
          "messages" => %{
            "subscribe_request" => %{"payload" => %{"type" => "object"}},
            "subscription_message" => %{
              "payload" => %{"type" => "object"},
              "examples" => [%{"payload" => %{"price" => 1}}]
            }
          }
        }
      },
      "operations" => %{
        "receive_ticker" => %{
          "action" => "receive",
          "channel" => %{"$ref" => "#/channels/ticker.(instrument)"},
          "messages" => [%{"$ref" => "#/channels/ticker.(instrument)/messages/subscribe_request"}]
        },
        "send_ticker" => %{
          "action" => "send",
          "channel" => %{"$ref" => "#/channels/ticker.(instrument)"},
          "messages" => [%{"$ref" => "#/channels/ticker.(instrument)/messages/subscription_message"}]
        }
      }
    }

    result = ContractSource.parse!(artifact("asyncapi-json"), Jason.encode!(document))

    assert Enum.map(result.operations, & &1["key"]) ==
             ["receive ticker.(instrument)", "send ticker.(instrument)"]

    assert Enum.all?(result.operations, fn operation ->
             "message_reference_direction_inversion" in operation["qualifiers"]
           end)

    assert result.metrics["message_reference_inversion_count"] == 2
    assert Enum.all?(result.operations, &(&1["response_schemas"] == ContractSource.unknown()))
    assert Enum.all?(result.operations, &(&1["message_schemas"]["status"] == "known"))
    assert Enum.any?(result.limitations, &(&1 =~ "opposite message direction"))
  end

  test "partial and prose declarations report capability limits without invented operations" do
    prose =
      "official-api-documentation"
      |> artifact()
      |> put_in(["expressiveness", "level"], "prose_documentation")

    result = ContractSource.parse!(prose, "provider prose")

    assert result.operations == []
    assert result.metrics == %{"operation_count" => 0}

    assert result.limitations == [
             "prose_documentation source fixture has no mechanically normalized operation inventory."
           ]
  end

  test "comparison keeps axes independent, reports field differences, and is deterministic" do
    {root, manifest, authored} = comparison_fixture()

    facts = [
      %{
        "venue" => "fixture",
        "contract_scope" => "current_rest",
        "operation_key" => "GET /api/v1/status",
        "runtime_scope" => "carved",
        "evidence" => "unverified",
        "reachability" => "safe"
      }
    ]

    first = ContractComparator.compare_venue!(manifest, authored, root, facts)
    second = ContractComparator.compare_venue!(manifest, authored, root, facts)
    current = first["surfaces"]["current_rest"]
    status = Enum.find(current["operations"], &(&1["operation_key"] == "GET /api/v1/status"))

    assert first == second
    assert Jason.encode!(first, pretty: true) == Jason.encode!(second, pretty: true)
    assert current["provider_count"] == 2
    assert current["authored_count"] == 2
    assert current["shared_count"] == 1
    assert current["provider_only_count"] == 1
    assert current["authored_only_count"] == 1

    assert status["axes"] == %{
             "relation" => "shared",
             "runtime_scope" => "carved",
             "evidence" => "unverified",
             "reachability" => "safe",
             "contract_scope" => "current_rest"
           }

    assert status["field_differences"] != []

    upcoming = first["surfaces"]["upcoming_rest"]
    assert upcoming["current_runtime_denominator"] == false
    assert upcoming["current_runtime_missing_count"] == 0
  end

  test "comparison rejects artifact bytes that do not match the authority manifest" do
    {root, manifest, authored} = comparison_fixture()
    path = Path.join([root, "fixture", "openapi.json"])
    File.write!(path, "corrupted")

    assert_raise Mix.Error, ~r/byte count differs from manifest/, fn ->
      ContractComparator.compare_venue!(manifest, authored, root)
    end
  end

  test "missing judgments default to unknown and missing evidence defaults to unverified" do
    {root, manifest, authored} = comparison_fixture()
    report = ContractComparator.compare_venue!(manifest, authored, root)
    current = report["surfaces"]["current_rest"]
    provider_only = Enum.find(current["operations"], &(&1["axes"]["relation"] == "provider_only"))

    assert provider_only["axes"]["runtime_scope"] == "unknown"
    assert provider_only["axes"]["evidence"] == "unverified"
    assert provider_only["axes"]["reachability"] == "unknown"
  end

  test "authored inventory preserves unknown parameters without unified declarations" do
    {root, manifest, authored} = comparison_fixture()

    authored =
      authored
      |> put_in(["endpoints", "unified"], nil)
      |> put_in(["endpoints", "request", "shape", "public", "endpoints"], [
        %{"http_verb" => "GET", "path_template" => "status", "path_params" => nil}
      ])
      |> put_in(["raw", "url_templates"], %{})
      |> put_in(["raw", "describe"], %{"urls" => %{"api" => "https://provider.example/api/v1"}})

    report = ContractComparator.compare_venue!(manifest, authored, root)
    [authored_status] = report["surfaces"]["current_rest"]["operations"] |> hd() |> Map.fetch!("authored")

    assert authored_status["runtime_scope"] == "raw_only"
    assert authored_status["parameters"] == ContractSource.unknown()
  end

  test "an artifact omitting the completeness gate degrades to no claim instead of raising" do
    {root, manifest, authored} = comparison_fixture()

    manifest =
      update_in(manifest, ["artifacts"], fn [source] ->
        [update_in(source, ["authority"], &Map.delete(&1, "completeness_gate"))]
      end)

    report = ContractComparator.compare_venue!(manifest, authored, root)
    current = report["surfaces"]["current_rest"]

    refute current["completeness_claim"]
    assert current["source_capability"] == "partial_machine_inventory"
  end

  test "registered facts reject invalid axes and operations outside the union" do
    root = temporary_directory("facts")
    path = Path.join(root, "facts.json")

    File.write!(
      path,
      Jason.encode!(%{
        "schema_version" => 1,
        "operations" => [
          %{
            "venue" => "fixture",
            "contract_scope" => "current_rest",
            "operation_key" => "GET /api/v1/status",
            "evidence" => "assumed"
          }
        ]
      })
    )

    assert_raise Mix.Error, ~r/invalid evidence "assumed"/, fn ->
      ContractComparator.load_facts(path)
    end

    File.write!(
      path,
      Jason.encode!(%{
        "schema_version" => 1,
        "operations" => [
          %{
            "venue" => "fixture",
            "contract_scope" => "current_rest",
            "operation_key" => "GET /api/v1/status",
            "evidence" => "verified",
            "evidence_source" => "registered_live_capture"
          }
        ]
      })
    )

    assert_raise Mix.Error, ~r/evidence verified requires the validated provider-operation capture corpus/, fn ->
      ContractComparator.load_facts(path)
    end

    {artifact_root, manifest, authored} = comparison_fixture()

    assert_raise Mix.Error, ~r/unknown operation current_rest GET \/missing/, fn ->
      ContractComparator.compare_venue!(manifest, authored, artifact_root, [
        %{
          "venue" => "fixture",
          "contract_scope" => "current_rest",
          "operation_key" => "GET /missing"
        }
      ])
    end
  end

  test "all ten venues emit four scoped reports or explicit source capability limits" do
    artifact_root = temporary_directory("empty-authority")
    reports = ContractComparator.compare_all!(artifact_root)

    assert Enum.map(reports, & &1["venue"]) == AuthorityCorpus.venues()

    for report <- reports do
      assert report["surfaces"] |> Map.keys() |> Enum.sort() ==
               ~w(current_rest current_websocket upcoming_rest upcoming_websocket)

      for {_surface, comparison} <- report["surfaces"] do
        refute comparison["completeness_claim"]
        assert comparison["source_capability"] in ~w(unavailable source_capability_limited)

        for operation <- comparison["operations"] do
          assert operation["axes"]["relation"] in ~w(shared provider_only authored_only)
          assert operation["axes"]["runtime_scope"] in ~w(unified raw_only carved not_implemented unknown)
          assert operation["axes"]["evidence"] in ~w(verified unverified)
          assert operation["axes"]["reachability"] in ~w(safe unsafe unreachable unknown)
          assert operation["axes"]["contract_scope"] in Map.keys(report["surfaces"])
        end
      end
    end
  end

  test "registered provider captures are the only facts that advance evidence" do
    artifact_root = temporary_directory("registered-provider-evidence")
    report = Enum.find(ContractComparator.compare_all!(artifact_root), &(&1["venue"] == "deribit"))
    operations = report["surfaces"]["current_rest"]["operations"]

    get_time = Enum.find(operations, &(&1["operation_key"] == "GET /api/v2/public/get_time"))
    ticker = Enum.find(operations, &(&1["operation_key"] == "GET /api/v2/public/ticker"))

    assert get_time["axes"]["evidence"] == "verified"
    assert get_time["axes"]["reachability"] == "safe"
    assert ticker["axes"]["evidence"] == "verified"
  end

  test "Deribit current and historical REST baselines bind the task-554 semantic diff" do
    manifest = Bourse.JsonDocument.decode_file!(Path.join([@authority_root, "deribit", "manifest.json"]))
    baseline = Bourse.JsonDocument.decode_file!(Path.join([@authority_root, "deribit", "contract-baselines.json"]))

    semantic_diff =
      Bourse.JsonDocument.decode_file!(Path.join([@authority_root, "deribit", "current-rest-drift-2026-08-10.json"]))

    current_artifact = Enum.find(manifest["artifacts"], &(&1["id"] == "api-openapi"))
    current = baseline["surfaces"]["current_rest"]
    historical = baseline["historical_current_rest"]
    prior_counts = semantic_diff["operation_delta"]["authored_relation_counts"]

    assert current["sha256"] == current_artifact["sha256"]
    assert current["upstream_pin"] == current_artifact["upstream_pin"]
    assert current["expected"]["provider_count"] == semantic_diff["current"]["operation_count"]
    assert current["expected"]["authored_count"] == prior_counts["authored"]
    assert current["expected"]["shared_count"] == prior_counts["overlap"]
    assert current["expected"]["provider_only_count"] == prior_counts["provider_only"]
    assert current["expected"]["authored_only_count"] == prior_counts["authored_only"]
    assert historical["sha256"] == semantic_diff["prior"]["sha256"]
    assert historical["expected"] == Map.take(current["expected"], Map.keys(historical["expected"]))

    assert baseline["surfaces"]["upcoming_rest"]["sha256"] != current["sha256"]
    assert baseline["surfaces"]["current_websocket"]["artifact_id"] == "current-asyncapi"
    assert baseline["surfaces"]["upcoming_websocket"]["artifact_id"] == "upcoming-asyncapi"
  end

  test "Mix task writes a limitation report without network access" do
    artifact_root = temporary_directory("task-artifacts")
    output_root = Path.join(temporary_directory("task-output-parent"), "reports")
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    assert :ok =
             ContractCompare.run([
               "--artifacts",
               artifact_root,
               "--output",
               output_root,
               "--venue",
               "derive"
             ])

    report = Bourse.JsonDocument.decode_file!(Path.join(output_root, "derive.json"))
    assert report["venue"] == "derive"
    assert report["surfaces"]["current_rest"]["source_capability"] == "source_capability_limited"
    assert_receive {:mix_shell, :info, [message]}
    assert message =~ "derive:"
  end

  defp comparison_fixture do
    root = temporary_directory("comparison")
    contents = Jason.encode!(openapi_document())
    path = Path.join([root, "fixture", "openapi.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)

    source =
      "openapi-json"
      |> artifact()
      |> Map.merge(%{
        "filename" => "openapi.json",
        "sha256" => AuthorityCorpus.sha256(contents),
        "bytes" => byte_size(contents),
        "scope" => [
          %{
            "surface" => "current_rest",
            "coverage" => "complete",
            "limitations" => ["Fixture REST only."]
          }
        ],
        "authority" => %{
          "classification" => "provider_owned",
          "semantic_authority" => true,
          "completeness_gate" => true
        }
      })

    manifest = %{"venue" => "fixture", "artifacts" => [source]}

    authored = %{
      "auth" => %{"authenticated_sections" => []},
      "endpoints" => %{
        "unified" => %{"fetchStatus" => ["publicGetStatus"]},
        "request" => %{
          "shape" => %{
            "public" => %{
              "endpoints" => [
                %{"http_verb" => "GET", "path_template" => "status", "path_params" => []},
                %{"http_verb" => "GET", "path_template" => "local", "path_params" => []}
              ]
            }
          }
        }
      },
      "raw" => %{
        "url_templates" => %{
          "public" => %{"url_prefix" => "https://provider.example/api/v1/"}
        }
      },
      "websocket" => %{"subscribe" => %{"channels" => %{}}}
    }

    {root, manifest, authored}
  end

  defp openapi_document do
    %{
      "openapi" => "3.0.0",
      "servers" => [%{"url" => "https://provider.example/api/v1"}],
      "security" => [%{"apiKey" => []}],
      "paths" => %{
        "/orders/{id}" => %{
          "post" => %{
            "parameters" => [
              %{
                "name" => "id",
                "in" => "path",
                "required" => true,
                "schema" => %{"type" => "string"},
                "example" => "abc"
              }
            ],
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"type" => "object"},
                    "example" => %{"id" => "abc"}
                  }
                }
              }
            }
          }
        },
        "/status" => %{
          "get" => %{
            "security" => nil,
            "parameters" => [%{"name" => "verbose", "in" => "query"}],
            "responses" => %{"200" => %{"description" => "ok"}}
          }
        }
      }
    }
  end

  defp artifact(kind) do
    %{
      "id" => "fixture",
      "kind" => kind,
      "source_url" => "https://provider.example/spec",
      "retrieved_at" => "2026-08-10",
      "upstream_pin" => %{"type" => "fixture", "value" => "1"},
      "sha256" => String.duplicate("0", 64),
      "bytes" => 1,
      "freshness" => %{"status" => "initial_baseline"},
      "expressiveness" => %{"level" => "typed_openapi", "limitations" => ["Fixture only."]},
      "scope" => [],
      "authority" => %{"completeness_gate" => false}
    }
  end

  defp known(value), do: ContractSource.known(value)

  defp temporary_directory(label) do
    path = Path.join(System.tmp_dir!(), "contract-compare-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
