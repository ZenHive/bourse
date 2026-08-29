defmodule Mix.Tasks.Bourse.ContractSourceTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Bourse.ContractSource

  test "normalizes a rich OpenAPI document without inventing absent facts" do
    document = %{
      "openapi" => "3.0.0",
      "servers" => [%{"url" => "https://api.example.test/v1/"}],
      "security" => [%{"apiKey" => []}],
      "components" => %{
        "parameters" => %{
          "symbol" => %{"name" => "symbol", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}
        },
        "requestBodies" => %{
          "order" => %{
            "required" => true,
            "content" => %{"application/json" => %{"schema" => %{"type" => "object"}, "example" => %{"size" => 1}}}
          }
        },
        "responses" => %{
          "order" => %{
            "content" => %{
              "application/json" => %{
                "schema" => %{"type" => "object"},
                "examples" => %{"filled" => %{"value" => %{"status" => "filled"}}}
              }
            }
          }
        }
      },
      "paths" => %{
        "/orders/{symbol}" => %{
          "parameters" => [%{"$ref" => "#/components/parameters/symbol"}],
          "post" => %{
            "tags" => ["WebSocket Only"],
            "security" => [],
            "requestBody" => %{"$ref" => "#/components/requestBodies/order"},
            "responses" => %{"200" => %{"$ref" => "#/components/responses/order"}}
          }
        },
        "/ticker" => %{
          "servers" => [%{"url" => "https://api.example.test/market"}],
          "get" => %{
            "parameters" => [
              %{"name" => "limit", "in" => "query", "type" => "integer", "example" => 10},
              %{"name" => "cursor", "in" => "query", "schema" => %{"example" => "next"}}
            ],
            "responses" => %{"200" => %{"schema" => %{"type" => "array"}}}
          }
        }
      }
    }

    result = ContractSource.parse!(artifact("openapi-json"), Jason.encode!(document))

    assert result.metrics == %{
             "operation_count" => 2,
             "path_count" => 2,
             "unknown_authentication_count" => 0,
             "websocket_only_operation_count" => 1
           }

    order = Enum.find(result.operations, &(&1["method"] == "POST"))
    assert order["key"] == "POST /v1/orders/{symbol}"
    assert order["authentication"] == ContractSource.known(%{"required" => false, "schemes" => []})
    assert order["qualifiers"] == ["websocket_only"]
    assert order |> get_in(["parameters", "value"]) |> length() == 2
    assert get_in(order, ["response_schemas", "status"]) == "known"
    assert order |> get_in(["examples", "value"]) |> length() == 2

    ticker = Enum.find(result.operations, &(&1["method"] == "GET"))
    assert ticker["path"] == "/market/ticker"
    assert ticker |> get_in(["parameters", "value"]) |> Enum.map(& &1["name"]) == ["cursor", "limit"]
    assert Enum.any?(result.limitations, &String.contains?(&1, "documentation"))
  end

  test "normalizes OpenAPI YAML and Swagger basePath" do
    yaml = """
    swagger: "2.0"
    basePath: /api/
    paths:
      /ping:
        get:
          responses: {}
    """

    assert %{operations: [%{"key" => "GET /api/ping"}]} =
             ContractSource.parse!(artifact("openapi-yaml"), yaml)
  end

  test "normalizes nested Postman requests, authentication, parameters, and examples" do
    document = %{
      "auth" => %{"type" => "apikey"},
      "item" => [
        %{
          "name" => "folder",
          "auth" => %{"type" => "noauth"},
          "item" => [
            %{
              "name" => "order",
              "request" => %{
                "method" => "post",
                "auth" => %{"type" => "bearer"},
                "url" => %{
                  "path" => ["v1", %{"value" => ":account"}, 7],
                  "query" => [%{"key" => "limit", "value" => "5"}],
                  "variable" => [%{"key" => "account", "value" => "demo", "disabled" => true}]
                },
                "body" => %{"raw" => ~s({"size":1})}
              },
              "response" => [%{"code" => 200, "body" => ~s({"id":"1"})}, %{"code" => 500}]
            },
            %{"name" => "ignored"}
          ]
        },
        %{
          "request" => %{"url" => %{"raw" => "{{base}}/trades/:id"}},
          "response" => [%{"code" => 200, "body" => "not-json"}]
        }
      ]
    }

    result = ContractSource.parse!(artifact("postman-collection"), Jason.encode!(document))
    assert result.metrics == %{"operation_count" => 2}
    assert Enum.map(result.operations, & &1["key"]) == ["POST /v1/{account}/7", "UNKNOWN /trades/{id}"]

    order = hd(result.operations)
    assert get_in(order, ["authentication", "value", "schemes"]) == ["bearer"]
    assert order |> get_in(["parameters", "value"]) |> length() == 2
    assert order |> get_in(["examples", "value"]) |> length() == 2
  end

  test "normalizes AsyncAPI v2 and v3 message directions" do
    messages = %{
      "subscription_message" => %{"payload" => %{"type" => "object"}, "examples" => [%{"op" => "sub"}]},
      "subscribe_request" => %{"payload" => %{"type" => "string"}}
    }

    v2 = %{
      "channels" => %{
        "prices/{symbol}" => %{
          "parameters" => %{"symbol" => %{"required" => true, "schema" => %{"type" => "string"}, "example" => "BTC"}},
          "publish" => %{"security" => [], "message" => %{"$ref" => "#/components/messages/subscription_message"}},
          "subscribe" => %{"message" => %{"$ref" => "#/components/messages/subscribe_request"}}
        }
      },
      "components" => %{"messages" => messages}
    }

    result = ContractSource.parse!(artifact("asyncapi-json"), Jason.encode!(v2))
    assert result.metrics["operation_count"] == 2
    assert result.metrics["channel_count"] == 1
    assert Enum.any?(result.operations, &(get_in(&1, ["message_schemas", "status"]) == "known"))

    v3 = %{
      "channels" => %{"prices" => %{}},
      "operations" => %{
        "listen" => %{
          "action" => "receive",
          "channel" => %{"$ref" => "#/channels/prices"},
          "messages" => [%{"$ref" => "#/components/messages/subscribe_request"}]
        }
      },
      "components" => %{"messages" => messages}
    }

    assert %{operations: [%{"key" => "receive prices", "qualifiers" => ["message_reference_direction_inversion"]}]} =
             ContractSource.parse!(artifact("asyncapi-json"), Jason.encode!(v3))
  end

  test "surface digests retain structural keys only for typed artifacts" do
    contents = Jason.encode!(%{"paths" => %{"//ping/" => %{"get" => %{}}}, "channels" => %{"ticker" => %{}}})
    digest = ContractSource.surface_digest(artifact("openapi-json"), contents)

    assert digest["key_sets"]["path_keys"] == ["/ping"]
    assert digest["key_sets"]["channel_keys"] == ["ticker"]
    assert digest["key_sets"]["operation_keys"] == ["GET /ping"]
    assert length(digest["entities"]) == 3
    assert ContractSource.hash_key_set([]) == nil

    prose = ContractSource.surface_digest(artifact("html"), "<html></html>")
    assert prose["key_sets"] == %{"channel_keys" => [], "operation_keys" => [], "path_keys" => []}
    assert Enum.any?(prose["limitations"], &String.contains?(&1, "cannot name"))
  end

  test "explicit facts and path normalization preserve unknowns" do
    assert ContractSource.known(false) == %{"status" => "known", "value" => false}
    assert ContractSource.unknown() == %{"status" => "unknown"}
    assert ContractSource.normalize_path(nil) == "/"
    assert ContractSource.normalize_path("//v1///orders/") == "/v1/orders"
  end

  defp artifact(kind) do
    %{
      "id" => "fixture",
      "kind" => kind,
      "expressiveness" => %{"level" => "typed"}
    }
  end
end
