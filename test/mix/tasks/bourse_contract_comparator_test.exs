defmodule Mix.Tasks.Bourse.ContractComparatorTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Bourse.AuthorityCorpus
  alias Mix.Tasks.Bourse.ContractComparator

  @empty_keys %{"channel_keys" => [], "operation_keys" => [], "path_keys" => []}

  test "diff names added, removed, and changed entities" do
    prior =
      digest(
        %{
          "channel_keys" => ["old"],
          "path_keys" => ["/same", "/gone"],
          "operation_keys" => ["GET /same"]
        },
        [entity("path", "/same", "aaa"), entity("path", "/gone", "gone")]
      )

    current =
      digest(
        %{
          "channel_keys" => ["new"],
          "path_keys" => ["/same", "/added"],
          "operation_keys" => ["GET /same", "POST /added"]
        },
        [entity("path", "/same", "bbb"), entity("path", "/added", "added")]
      )

    delta = ContractComparator.diff_surface_digests(prior, current)

    assert delta["added"] == %{
             "channel_keys" => ["new"],
             "operation_keys" => ["POST /added"],
             "path_keys" => ["/added"]
           }

    assert delta["removed"] == %{
             "channel_keys" => ["old"],
             "operation_keys" => [],
             "path_keys" => ["/gone"]
           }

    assert [%{"kind" => "path", "key" => "/same", "prior_sha256" => "aaa", "current_sha256" => "bbb"}] =
             delta["changed"]
  end

  test "authored operations resolve nested URLs, templates, auth, and runtime scope" do
    authored = authored_fixture()
    operations = ContractComparator.authored_rest_operations(authored)

    assert Enum.map(operations, & &1["key"]) == ["GET /private/orders/{id}", "POST /v2/ticker"]

    private = hd(operations)
    assert private["runtime_scope"] == "unified"
    assert private["authentication"]["value"]["required"]
    assert private |> get_in(["parameters", "value"]) |> Enum.map(& &1["name"]) == ["id"]

    public = List.last(operations)
    assert public["runtime_scope"] == "raw_only"
    refute public["authentication"]["value"]["required"]

    assert ContractComparator.authored_rest_authentication(authored) == %{
             "GET /private/orders/{id}" => [%{"authentication" => private["authentication"]}],
             "POST /v2/ticker" => [%{"authentication" => public["authentication"]}]
           }
  end

  test "comparison reports authored-only REST and websocket surfaces without artifacts" do
    manifest = %{"venue" => "fixture", "artifacts" => []}
    report = ContractComparator.compare_venue!(manifest, authored_fixture(), "/unused")

    assert report["semantic_effect"] == "none"
    assert get_in(report, ["surfaces", "current_rest", "source_capability"]) == "unavailable"
    assert get_in(report, ["surfaces", "current_rest", "authored_only_count"]) == 2
    assert get_in(report, ["surfaces", "current_websocket", "authored_only_count"]) == 4

    assert Enum.all?(get_in(report, ["surfaces", "current_rest", "operations"]), fn operation ->
             operation["axes"]["relation"] == "authored_only"
           end)
  end

  test "comparison parses materialized complete provider inventory and exposes all relations" do
    root = tmp_dir!()

    contents =
      Jason.encode!(%{
        "paths" => %{
          "/private/orders/{id}" => %{"get" => %{"security" => [%{"apiKey" => []}]}},
          "/provider-only" => %{"delete" => %{}}
        }
      })

    venue_dir = Path.join(root, "fixture")
    File.mkdir_p!(venue_dir)
    File.write!(Path.join(venue_dir, "openapi.json"), contents)

    artifact = %{
      "id" => "rest",
      "kind" => "openapi-json",
      "filename" => "openapi.json",
      "sha256" => AuthorityCorpus.sha256(contents),
      "bytes" => byte_size(contents),
      "upstream_pin" => %{"type" => "version", "value" => "1"},
      "expressiveness" => %{"level" => "typed_openapi", "limitations" => []},
      "scope" => [%{"surface" => "current_rest", "coverage" => "complete", "limitations" => []}],
      "authority" => %{"completeness_gate" => true},
      "freshness" => %{"status" => "reviewed_current"}
    }

    report =
      ContractComparator.compare_venue!(%{"venue" => "fixture", "artifacts" => [artifact]}, authored_fixture(), root)

    rest = get_in(report, ["surfaces", "current_rest"])

    assert rest["source_capability"] == "complete_machine_inventory"
    assert rest["provider_count"] == 2
    assert rest["shared_count"] == 1
    assert rest["provider_only_count"] == 1
    assert rest["authored_only_count"] == 1
    assert rest["current_runtime_missing_count"] == 1

    assert rest["operations"] |> Enum.map(& &1["axes"]["relation"]) |> Enum.sort() ==
             ["authored_only", "provider_only", "shared"]
  end

  test "registered facts classify authored operations and reject invalid authority claims" do
    manifest = %{"venue" => "fixture", "artifacts" => []}

    fact = %{
      "venue" => "fixture",
      "contract_scope" => "current_rest",
      "operation_key" => "GET /private/orders/{id}",
      "runtime_scope" => "carved",
      "evidence" => "unverified",
      "reachability" => "unsafe"
    }

    report = ContractComparator.compare_venue!(manifest, authored_fixture(), "/unused", [fact])
    operation = report |> get_in(["surfaces", "current_rest", "operations"]) |> hd()

    assert operation["axes"] == %{
             "contract_scope" => "current_rest",
             "evidence" => "unverified",
             "reachability" => "unsafe",
             "relation" => "authored_only",
             "runtime_scope" => "carved"
           }

    assert_raise Mix.Error, ~r/evidence verified cannot be declared/, fn ->
      ContractComparator.compare_venue!(manifest, authored_fixture(), "/unused", [%{fact | "evidence" => "verified"}])
    end
  end

  test "fact files and retained digests have explicit missing and validation paths" do
    root = tmp_dir!()
    assert ContractComparator.load_facts(nil) == []
    assert ContractComparator.load_surface_digest(root, "fixture", "missing") == nil

    assert_raise Mix.Error, ~r/missing surface digest/, fn ->
      ContractComparator.load_surface_digest!(root, "fixture", "missing")
    end

    path = Path.join(root, "facts.json")

    File.write!(
      path,
      Jason.encode!(%{
        "schema_version" => 1,
        "operations" => [
          %{
            "venue" => "fixture",
            "contract_scope" => "current_rest",
            "operation_key" => "GET /x",
            "reachability" => "unknown"
          }
        ]
      })
    )

    assert [%{"operation_key" => "GET /x"}] = ContractComparator.load_facts(path)

    File.write!(path, Jason.encode!(%{"schema_version" => 2, "operations" => []}))
    assert_raise Mix.Error, ~r/unsupported facts schema_version/, fn -> ContractComparator.load_facts(path) end
  end

  test "retained-surface review is unnamed when no digest exists" do
    root = tmp_dir!()
    artifact = %{"id" => "fixture", "kind" => "openapi-json", "expressiveness" => %{"level" => "typed"}}
    delta = ContractComparator.review_retained_surface("fixture", artifact, ~s({"paths":{}}), root)
    refute delta["named"]
    assert delta["added"] == @empty_keys
  end

  defp authored_fixture do
    %{
      "auth" => %{"authenticated_sections" => ["private"]},
      "endpoints" => %{
        "unified" => %{"orders" => ["privateGetGetOrdersId"]},
        "request" => %{
          "shape" => %{
            "private.get" => %{
              "endpoints" => [
                %{"http_verb" => "get", "path_template" => "orders/{id}", "path_params" => [%{"name" => "id"}]}
              ]
            },
            "public.post" => %{
              "endpoints" => [%{"http_verb" => "post", "path_template" => "ticker"}]
            }
          }
        }
      },
      "raw" => %{
        "describe" => %{
          "urls" => %{"api" => %{"private" => %{"get" => "https://api.test/private"}, "public" => "https://api.test/v1"}}
        },
        "url_templates" => %{"public.post" => %{"url_prefix" => "https://api.test/v2"}}
      },
      "websocket" => %{"subscribe" => %{"channels" => %{"public" => ["ticker", "trades", "ticker"]}}}
    }
  end

  defp digest(keys, entities) do
    %{
      "artifact_id" => "fixture",
      "source" => %{"sha256" => "source"},
      "key_set_sha256" => @empty_keys,
      "key_sets" => keys,
      "entities" => entities
    }
  end

  defp entity(kind, key, sha), do: %{"kind" => kind, "key" => key, "sha256" => sha}

  defp tmp_dir! do
    path = Path.join(System.tmp_dir!(), "bourse-contract-comparator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
