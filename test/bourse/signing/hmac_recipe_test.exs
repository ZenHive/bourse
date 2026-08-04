defmodule Bourse.Signing.HmacRecipeTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Defaults
  alias Bourse.Signing
  alias Bourse.Signing.HmacRecipe
  alias Bourse.Signing.SignedRequest
  alias Bourse.Spec

  @nonce_override 123_456

  @credentials %Credentials{
    api_key: "api-key",
    secret: "secret",
    password: "passphrase"
  }

  @recipe %{
    "auth_headers" => [
      %{"name" => "OK-ACCESS-KEY", "source" => "api_key"},
      %{"name" => "OK-ACCESS-PASSPHRASE", "source" => "passphrase"},
      %{"name" => "OK-ACCESS-TIMESTAMP", "source" => "timestamp"}
    ],
    "canonical_string" => %{
      "GET" => %{
        "components" => [
          %{"source" => "timestamp"},
          %{"source" => "method"},
          %{"source" => "path"},
          %{"source" => "literal", "value" => "?"},
          %{"source" => "query"}
        ]
      },
      "POST" => %{
        "components" => [
          %{"source" => "timestamp"},
          %{"source" => "method"},
          %{"source" => "path"},
          %{"source" => "body"}
        ]
      }
    },
    "crypto_op" => %{"algo" => "hmac_sha256"},
    "pre_sign_transforms" => [
      %{"op" => "base64_encode", "target" => "signature"},
      %{"op" => "json_encode", "target" => "body"}
    ],
    "signature_placement" => %{"key" => "OK-ACCESS-SIGN", "location" => "header"},
    "timestamp" => %{"format" => "iso8601", "source" => "timestamp_ms"}
  }

  @query_recipe %{
    "auth_headers" => [
      %{"name" => "X-MBX-APIKEY", "source" => "api_key"}
    ],
    "canonical_string" => %{
      "POST" => %{
        "components" => [
          %{"source" => "query"}
        ]
      }
    },
    "crypto_op" => %{"algo" => "hmac_sha256"},
    "pre_sign_transforms" => [
      %{"op" => "hex_encode", "target" => "signature"}
    ],
    "signature_placement" => %{"key" => "signature", "location" => "query"},
    "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
  }

  @spec_dir Path.expand("../../../priv/specs/json/output", __DIR__)

  @external_resource Path.join(@spec_dir, "weex.json")
  @external_resource Path.join(@spec_dir, "okx.json")
  @external_resource Path.join(@spec_dir, "authored/okx.json")
  @external_resource Path.join(@spec_dir, "bybit.json")
  @external_resource Path.join(@spec_dir, "authored/bybit.json")
  @external_resource Path.join(@spec_dir, "authored/binance.json")

  @weex_recipe @spec_dir
               |> Path.join("weex.json")
               |> File.read!()
               |> Jason.decode!()
               |> get_in(["auth", "sign_recipe", "private"])

  @okx_vendored_recipe "okx"
                       |> Spec.load!()
                       |> get_in(["auth", "sign_recipe", "private"])

  # Bybit uses branch_family: derived v5/openapi/unified_v3/contract_v3
  # branches (signed into X-BAPI-SIGN) + a legacy_else branch for non-v5 query
  # signing. crypto_op lives on the private section, not the branch.
  @bybit_recipe "bybit"
                |> Spec.load!()
                |> get_in(["auth", "sign_recipe", "private"])

  @binance_recipes "binance"
                   |> Spec.load!()
                   |> get_in(["auth", "sign_recipe"])

  describe "sign/3 with vendored okx recipe" do
    test "GET uses per-method canonical components" do
      request = %{
        method: :get,
        path: "/api/v5/account/balance",
        body: nil,
        params: %{"ccy" => "BTC"}
      }

      timestamp = "2026-06-14T12:34:56.789Z"
      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: @okx_vendored_recipe, timestamp: timestamp})
      expected_signature = hmac_base64(timestamp <> "GET" <> request.path <> "?ccy=BTC")

      assert {"OK-ACCESS-SIGN", expected_signature} in signed.headers
      assert signed.url == "/api/v5/account/balance?ccy=BTC"
    end

    test "POST uses per-method body components" do
      request = %{
        method: :post,
        path: "/api/v5/trade/order",
        body: nil,
        params: %{"instId" => "BTC-USDT", "side" => "buy"}
      }

      timestamp = "2026-06-14T12:34:56.789Z"
      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: @okx_vendored_recipe, timestamp: timestamp})
      expected_body = Jason.encode!(request.params)
      expected_signature = hmac_base64(timestamp <> "POST" <> request.path <> expected_body)

      assert signed.body == expected_body
      assert {"OK-ACCESS-SIGN", expected_signature} in signed.headers
    end
  end

  describe "sign/3 with vendored bybit branch_family recipe" do
    test "v5 GET selects the v5 branch and signs into X-BAPI-SIGN with inherited crypto_op" do
      request = %{
        method: :get,
        path: "/v5/account/wallet-balance",
        body: nil,
        params: %{"accountType" => "UNIFIED"}
      }

      timestamp = "1700000000000"
      recv = to_string(Defaults.recv_window_ms())

      signed =
        HmacRecipe.sign(request, @credentials, %{sign_recipe: @bybit_recipe, timestamp: timestamp})

      # v5 GET canonical: timestamp <> api_key <> recv_window <> query (rawencode).
      # crypto_op (hmac_sha256) is inherited from the private section, not the branch.
      payload = timestamp <> @credentials.api_key <> recv <> "accountType=UNIFIED"
      expected = payload |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert {"X-BAPI-SIGN", expected} in signed.headers
      assert {"X-BAPI-API-KEY", @credentials.api_key} in signed.headers
      assert {"X-BAPI-TIMESTAMP", timestamp} in signed.headers
      assert {"X-BAPI-RECV-WINDOW", recv} in signed.headers
    end

    test "v5 POST selects the v5 branch and signs the json body" do
      request = %{
        method: :post,
        path: "/v5/order/create",
        body: nil,
        params: %{"symbol" => "BTCUSDT", "side" => "Buy"}
      }

      timestamp = "1700000000000"
      recv = to_string(Defaults.recv_window_ms())

      signed =
        HmacRecipe.sign(request, @credentials, %{sign_recipe: @bybit_recipe, timestamp: timestamp})

      body_json = Jason.encode!(request.params)
      payload = timestamp <> @credentials.api_key <> recv <> body_json
      expected = payload |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.body == body_json
      assert {"X-BAPI-SIGN", expected} in signed.headers
    end

    test "legacy_else GET merges auth fields into the signed query and appends sign" do
      request = %{
        method: :get,
        path: "/asset/v3/private/transfer/asset-info/query",
        body: nil,
        params: %{"accountType" => "SPOT"}
      }

      timestamp = "1700000000000"
      recv = to_string(Defaults.recv_window_ms())

      signed =
        HmacRecipe.sign(request, @credentials, %{
          sign_recipe: @bybit_recipe,
          timestamp: timestamp
        })

      query = "accountType=SPOT&api_key=#{@credentials.api_key}&recv_window=#{recv}&timestamp=#{timestamp}"
      expected = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query <> "&sign=" <> expected
      assert signed.headers == []
    end

    # Bybit rejects the GET query form on legacy POST with 10001 "Request
    # parameter error: apiKey is missing" (verified live on testnet) — the auth
    # params and `sign` must travel in the JSON body, and nothing in the URL.
    test "legacy_else POST carries the signed params and sign in the JSON body, not the query" do
      request = %{
        method: :post,
        path: "/asset/v3/private/transfer/inter-transfer",
        body: nil,
        params: %{"coin" => "USDT"}
      }

      timestamp = "1700000000000"
      recv = to_string(Defaults.recv_window_ms())

      signed =
        HmacRecipe.sign(request, @credentials, %{sign_recipe: @bybit_recipe, timestamp: timestamp})

      query = "api_key=#{@credentials.api_key}&coin=USDT&recv_window=#{recv}&timestamp=#{timestamp}"
      expected = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path
      assert {"Content-Type", "application/json"} in signed.headers

      assert Jason.decode!(signed.body) == %{
               "api_key" => @credentials.api_key,
               "coin" => "USDT",
               "recv_window" => recv,
               "sign" => expected,
               "timestamp" => timestamp
             }
    end

    # Bourse form-encodes the legacy POST body when the path contains "spot". No
    # spot/v3 POST private endpoint exists in the vendored catalog, so this pins
    # the authored rule that no live endpoint currently exercises.
    test "legacy_else POST form-encodes the body for spot paths" do
      request = %{method: :post, path: "/spot/v3/private/order", body: nil, params: %{"symbol" => "BTCUSDT"}}
      timestamp = "1700000000000"
      recv = to_string(Defaults.recv_window_ms())

      signed =
        HmacRecipe.sign(request, @credentials, %{sign_recipe: @bybit_recipe, timestamp: timestamp})

      query = "api_key=#{@credentials.api_key}&recv_window=#{recv}&symbol=BTCUSDT&timestamp=#{timestamp}"
      expected = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path
      assert {"Content-Type", "application/x-www-form-urlencoded"} in signed.headers
      assert URI.decode_query(signed.body) == URI.decode_query(query <> "&sign=" <> expected)
    end

    test "every legacy POST endpoint sends api_key in the body and no query string" do
      legacy_prefixes = ["spot/v3/", "asset/v3/", "user/v3/", "fht/compliance-tax/v3/", "v2/"]

      posts =
        Enum.filter(Bourse.Bybit.__endpoints__(), fn endpoint ->
          endpoint.authenticated and endpoint.method == :post and
            Enum.any?(legacy_prefixes, &String.starts_with?(endpoint.path, &1))
        end)

      assert posts != []

      for endpoint <- posts do
        signed =
          HmacRecipe.sign(
            %{method: :post, path: endpoint.path, body: nil, params: %{"coin" => "BTC"}},
            @credentials,
            %{sign_recipe: @bybit_recipe, timestamp: "1700000000000"}
          )

        refute String.contains?(signed.url, "?"), "legacy POST #{endpoint.path} must not sign via the query"

        assert String.contains?(signed.body, "api_key"),
               "legacy POST #{endpoint.path} must carry api_key in the body"
      end
    end

    test "all Bybit non-v5 legacy private endpoint paths resolve to a signer" do
      legacy_prefixes = ["spot/v3/", "asset/v3/", "user/v3/", "fht/compliance-tax/v3/", "v2/"]

      endpoints =
        Enum.filter(Bourse.Bybit.__endpoints__(), fn endpoint ->
          endpoint.authenticated and Enum.any?(legacy_prefixes, &String.starts_with?(endpoint.path, &1))
        end)

      assert endpoints != []

      for endpoint <- endpoints do
        signed =
          HmacRecipe.sign(
            %{method: endpoint.method, path: endpoint.path, body: nil, params: %{"coin" => "BTC"}},
            @credentials,
            %{sign_recipe: @bybit_recipe, timestamp: "1700000000000"}
          )

        refute match?({:error, {:unsupported_signing, _exchange}}, signed),
               "unsupported signing for #{endpoint.method} #{endpoint.path}"
      end
    end
  end

  describe "branch_family selection edge cases" do
    test "explicit deferred branches still abstain without falling through" do
      recipe = %{
        "exchange" => %{"id" => "synthetic"},
        "branch_family" => %{
          "discriminator" => "path_substring",
          "branches" => [
            %{"key" => "legacy", "match" => %{"otherwise" => true}, "status" => "deferred"}
          ]
        },
        "crypto_op" => %{"algo" => "hmac_sha256"}
      }

      request = %{method: :get, path: "/legacy", body: nil, params: %{}}

      assert HmacRecipe.sign(request, @credentials, %{sign_recipe: recipe}) ==
               {:error, {:unsupported_signing, "synthetic"}}
    end

    test "resolves branch_family nested under auth.sign_recipe.private" do
      wrapped = %{"auth" => %{"sign_recipe" => %{"private" => @bybit_recipe}}}
      request = %{method: :get, path: "/v5/account/info", body: nil, params: %{"x" => "1"}}

      signed =
        HmacRecipe.sign(request, @credentials, %{sign_recipe: wrapped, timestamp: "1700000000000"})

      assert Enum.any?(signed.headers, fn {k, _v} -> k == "X-BAPI-SIGN" end)
    end

    test "unknown discriminator abstains with :unknown_discriminator (never silently signs)" do
      recipe = %{
        "exchange" => %{"id" => "synthetic"},
        "branch_family" => %{"discriminator" => "unknown_kind", "branches" => []},
        "canonical_string" => %{"GET" => %{"components" => [%{"source" => "path"}]}},
        "crypto_op" => %{"algo" => "hmac_sha256"},
        "signature_placement" => %{"key" => "X-SIGN", "location" => "header"}
      }

      request = %{method: :get, path: "/abc", body: nil, params: %{}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert HmacRecipe.sign(request, @credentials, %{sign_recipe: recipe}) ==
                   {:error, {:unsupported_signing, "synthetic"}}
        end)

      assert log =~ "unknown_discriminator"
    end

    test "no matching branch and no otherwise abstains with :no_branch_matched (never silently signs)" do
      recipe = %{
        "exchange" => %{"id" => "synthetic"},
        "branch_family" => %{
          "discriminator" => "path_substring",
          "branches" => [
            %{
              "key" => "v5",
              "match" => %{"path_contains" => "v5"},
              "status" => "derived",
              "canonical_string" => %{"GET" => %{"components" => [%{"source" => "path"}]}},
              "signature_placement" => %{"key" => "X-BR", "location" => "header"}
            }
          ]
        },
        "canonical_string" => %{"GET" => %{"components" => [%{"source" => "path"}]}},
        "crypto_op" => %{"algo" => "hmac_sha256"},
        "signature_placement" => %{"key" => "X-TOP", "location" => "header"}
      }

      request = %{method: :get, path: "/legacy/order", body: nil, params: %{}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert HmacRecipe.sign(request, @credentials, %{sign_recipe: recipe}) ==
                   {:error, {:unsupported_signing, "synthetic"}}
        end)

      assert log =~ "no_branch_matched"
    end
  end

  describe "sign/3 with vendored weex recipe" do
    test "GET appends query suffix for non-batch paths" do
      request = %{
        method: :get,
        path: "api/v3/account",
        body: nil,
        params: %{"ccy" => "BTC"}
      }

      timestamp = "1710000000000"
      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: @weex_recipe, timestamp: timestamp})
      expected_signature = hmac_base64(timestamp <> "GET" <> "/" <> request.path <> "?ccy=BTC")

      assert {"ACCESS-SIGN", expected_signature} in signed.headers
      assert signed.url == request.path <> "?ccy=BTC"
    end

    test "DELETE appends query suffix for non-batch paths" do
      request = %{
        method: :delete,
        path: "api/v3/order",
        body: nil,
        params: %{"orderId" => "1"}
      }

      timestamp = "1710000000000"
      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: @weex_recipe, timestamp: timestamp})
      expected_signature = hmac_base64(timestamp <> "DELETE" <> "/" <> request.path <> "?orderId=1")

      assert {"ACCESS-SIGN", expected_signature} in signed.headers
      assert signed.url == request.path <> "?orderId=1"
    end

    test "POST json-encodes body for non-batch paths" do
      request = %{
        method: :post,
        path: "api/v3/order",
        body: nil,
        params: %{"symbol" => "BTCUSDT", "side" => "buy"}
      }

      timestamp = "1710000000000"
      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: @weex_recipe, timestamp: timestamp})
      expected_body = Jason.encode!(request.params)
      expected_signature = hmac_base64(timestamp <> "POST" <> "/" <> request.path <> expected_body)

      assert signed.body == expected_body
      assert {"ACCESS-SIGN", expected_signature} in signed.headers
    end

    test "batch paths sign json body without query suffix" do
      request = %{
        method: :post,
        path: "api/v3/order/batch",
        body: nil,
        params: [%{"symbol" => "BTCUSDT", "side" => "buy"}]
      }

      timestamp = "1710000000000"
      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: @weex_recipe, timestamp: timestamp})
      expected_body = Jason.encode!(request.params)
      expected_signature = hmac_base64(timestamp <> "POST" <> "/" <> request.path <> expected_body)

      assert signed.body == expected_body
      assert signed.url == request.path
      assert {"ACCESS-SIGN", expected_signature} in signed.headers
    end
  end

  describe "canonical component resolution" do
    test "selects nested sub-recipe matching the request path" do
      recipe = %{
        "private" => %{
          "auth_headers" => [%{"name" => "X-DEFAULT-KEY", "source" => "api_key"}],
          "canonical_string" => %{
            "GET" => %{"components" => [%{"source" => "literal", "value" => "default"}]},
            "POST" => %{"components" => [%{"source" => "literal", "value" => "default"}]}
          },
          "crypto_op" => %{"algo" => "hmac_sha256"},
          "pre_sign_transforms" => [%{"op" => "hex_encode", "target" => "signature"}],
          "signature_placement" => %{"key" => "X-DEFAULT-SIGN", "location" => "header"},
          "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
        },
        "v2" => %{
          "private" => %{
            "auth_headers" => [
              %{"name" => "X-V2-KEY", "source" => "api_key"},
              %{"name" => "X-V2-TIMESTAMP", "source" => "timestamp"}
            ],
            "canonical_string" => %{
              "GET" => %{
                "components" => [
                  %{"source" => "timestamp"},
                  %{"source" => "method"},
                  %{"source" => "path"}
                ]
              }
            },
            "crypto_op" => %{"algo" => "hmac_sha256"},
            "pre_sign_transforms" => [%{"op" => "base64_encode", "target" => "signature"}],
            "signature_placement" => %{"key" => "X-V2-SIGN", "location" => "header"},
            "timestamp" => %{"format" => "iso8601", "source" => "timestamp_ms"}
          }
        }
      }

      request = %{method: :get, path: "/api/v2/accounts", body: nil, params: %{}}
      timestamp = "2026-06-17T12:34:56.789Z"

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: recipe, timestamp: timestamp})
      expected_signature = hmac_base64(timestamp <> "GET" <> request.path)

      assert {"X-V2-KEY", @credentials.api_key} in signed.headers
      assert {"X-V2-TIMESTAMP", timestamp} in signed.headers
      assert {"X-V2-SIGN", expected_signature} in signed.headers
      refute Enum.any?(signed.headers, &match?({"X-DEFAULT-KEY", _value}, &1))
    end

    test "prefers exact method key over wildcard" do
      recipe = %{
        "auth_headers" => [],
        "canonical_string" => %{
          "*" => %{"components" => [%{"source" => "literal", "value" => "wildcard"}]},
          "GET" => %{"components" => [%{"source" => "literal", "value" => "exact"}]}
        },
        "crypto_op" => %{"algo" => "hmac_sha256"},
        "pre_sign_transforms" => [%{"op" => "hex_encode", "target" => "signature"}],
        "signature_placement" => %{"key" => "X-SIGNATURE", "location" => "header"},
        "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
      }

      signed =
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe}
        )

      expected_signature = "exact" |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()
      assert {"X-SIGNATURE", expected_signature} in signed.headers
    end

    test "filters components by methods and path predicates" do
      recipe = %{
        "auth_headers" => [],
        "canonical_string" => %{
          "*" => %{
            "components" => [
              %{"source" => "literal", "value" => "always"},
              %{"methods" => ["POST"], "source" => "literal", "value" => "post-only"},
              %{"path_contains" => "batch", "source" => "literal", "value" => "batch-only"},
              %{
                "methods" => ["GET"],
                "source" => "literal",
                "unless_path_contains" => "batch",
                "value" => "get-non-batch"
              }
            ]
          }
        },
        "crypto_op" => %{"algo" => "hmac_sha256"},
        "pre_sign_transforms" => [%{"op" => "hex_encode", "target" => "signature"}],
        "signature_placement" => %{"key" => "X-SIGNATURE", "location" => "header"},
        "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
      }

      get_signed =
        HmacRecipe.sign(
          %{method: :get, path: "api/v3/account", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe}
        )

      get_signature = "alwaysget-non-batch" |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()
      assert {"X-SIGNATURE", get_signature} in get_signed.headers

      batch_signed =
        HmacRecipe.sign(
          %{method: :get, path: "api/v3/order/batch", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe}
        )

      batch_signature = "alwaysbatch-only" |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()
      assert {"X-SIGNATURE", batch_signature} in batch_signed.headers
    end
  end

  describe "sign/3" do
    test "builds a header signature from GET canonical components" do
      request = %{
        method: :get,
        path: "/api/v5/account/balance",
        body: nil,
        params: %{"ccy" => "BTC"}
      }

      timestamp = "2026-06-14T12:34:56.789Z"
      config = %{sign_recipe: @recipe, timestamp: timestamp}

      signed = HmacRecipe.sign(request, @credentials, config)
      expected_signature = hmac_base64(timestamp <> "GET" <> request.path <> "?ccy=BTC")

      assert signed.url == "/api/v5/account/balance?ccy=BTC"
      assert signed.body == nil
      assert {"OK-ACCESS-SIGN", expected_signature} in signed.headers
      assert {"OK-ACCESS-KEY", "api-key"} in signed.headers
      assert {"OK-ACCESS-PASSPHRASE", "passphrase"} in signed.headers
      assert {"OK-ACCESS-TIMESTAMP", timestamp} in signed.headers
    end

    test "omits query separator from GET payload when query is empty" do
      request = %{
        method: :get,
        path: "/api/v5/account/balance",
        body: nil,
        params: %{}
      }

      timestamp = "2026-06-14T12:34:56.789Z"
      config = %{sign_recipe: @recipe, timestamp: timestamp}

      signed = HmacRecipe.sign(request, @credentials, config)
      expected_signature = hmac_base64(timestamp <> "GET" <> request.path)

      assert signed.url == request.path
      assert {"OK-ACCESS-SIGN", expected_signature} in signed.headers
      refute Enum.any?(signed.headers, fn {k, _} -> k == "Content-Type" end)
    end

    test "json-encodes POST params before signing body components" do
      request = %{
        method: :post,
        path: "/api/v5/trade/order",
        body: nil,
        params: %{"instId" => "BTC-USDT", "side" => "buy"}
      }

      timestamp = "2026-06-14T12:34:56.789Z"
      config = %{sign_recipe: @recipe, timestamp: timestamp}

      signed = HmacRecipe.sign(request, @credentials, config)
      expected_body = Jason.encode!(request.params)
      expected_signature = hmac_base64(timestamp <> "POST" <> request.path <> expected_body)

      assert signed.url == request.path
      assert signed.body == expected_body
      assert {"OK-ACCESS-SIGN", expected_signature} in signed.headers
      assert {"Content-Type", "application/json"} in signed.headers
    end

    test "keeps query-placed POST signatures in the URL" do
      request = %{
        method: :post,
        path: "/api/v3/order",
        body: nil,
        params: %{"symbol" => "BTCUSDT", "timestamp" => "123"}
      }

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: @query_recipe})
      query = "symbol=BTCUSDT&timestamp=123"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query <> "&signature=" <> signature
      assert signed.body == nil
      assert {"X-MBX-APIKEY", "api-key"} in signed.headers
    end

    test "honors sorted query keys and post-encode replacements" do
      component = %{
        "encoder" => "urlencode",
        "key_order" => "sorted",
        "replacements" => [%{"from" => "%24", "to" => "$"}],
        "source" => "query"
      }

      request = %{
        method: :get,
        path: "/api/v2/mix/order",
        body: nil,
        params: [{"symbol", "BTC$USDT"}, {"limit", 100}]
      }

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      query = "limit=100&symbol=BTC$USDT"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "honors sorted query keys without replacements" do
      component = %{"encoder" => "urlencode", "key_order" => "sorted", "source" => "query"}
      request = %{method: :get, path: "/private", body: nil, params: [{"z", 1}, {"a", 2}]}

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      query = "a=2&z=1"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "honors insertion query key order" do
      component = %{"encoder" => "urlencode", "key_order" => "insertion", "source" => "query"}
      request = %{method: :get, path: "/api/v5/account", body: nil, params: [{"z", 1}, {"a", 2}]}

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      query = "z=1&a=2"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "honors array-repeat query encoding" do
      component = %{"encoder" => "urlencodeWithArrayRepeat", "key_order" => "insertion", "source" => "query"}

      request = %{
        method: :get,
        path: "/api/v3/brokerage/orders",
        body: nil,
        params: [{"order_ids", ["one", "two"]}, {"limit", 2}]
      }

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      query = "order_ids=one&order_ids=two&limit=2"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "encodes Binance scalar arrays as JSON query values" do
      component = %{"encoder" => "urlencodeJsonArray", "key_order" => "insertion", "source" => "query"}

      request = %{
        method: :get,
        path: "/api/v3/ticker/price",
        body: nil,
        params: [{"symbols", ["BTCUSDT", "ETHUSDT"]}]
      }

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      query = "symbols=%5B%22BTCUSDT%22%2C%22ETHUSDT%22%5D"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "authored Binance dust recipe encodes multiple assets as one comma-separated field" do
      request = %{
        method: :post,
        path: "/asset/dust",
        body: nil,
        params: %{"asset" => ["BTC", "USDT"]}
      }

      signed =
        HmacRecipe.sign(request, @credentials, %{
          sign_recipe: @binance_recipes,
          sign_recipe_section: "sapi",
          timestamp: "1700000000000"
        })

      [_path, query_with_signature] = String.split(signed.url, "?", parts: 2)
      [query, signature] = String.split(query_with_signature, "&signature=", parts: 2)

      assert String.contains?(query, "asset=BTC%2CUSDT")
      assert URI.decode_query(query)["asset"] == "BTC,USDT"
      refute String.contains?(query, "asset%5B%5D")
      refute String.contains?(query, "%5B%22BTC")
      assert signature == query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()
    end

    test "authored Binance dust preview keeps the default JSON-array dialect" do
      request = %{
        method: :post,
        path: "/asset/dust-btc",
        body: nil,
        params: %{"symbols" => ["BTCUSDT", "ETHUSDT"]}
      }

      signed =
        HmacRecipe.sign(request, @credentials, %{
          sign_recipe: @binance_recipes,
          sign_recipe_section: "sapi",
          timestamp: "1700000000000"
        })

      [_path, query_with_signature] = String.split(signed.url, "?", parts: 2)
      [query, _signature] = String.split(query_with_signature, "&signature=", parts: 2)

      assert URI.decode_query(query)["symbols"] == ~s(["BTCUSDT","ETHUSDT"])
    end

    test "authored Binance dust recipe rejects nested asset values" do
      request = %{
        method: :post,
        path: "/asset/dust",
        body: nil,
        params: %{"asset" => [%{"code" => "BTC"}]}
      }

      assert_raise ArgumentError, ~r/unsupported nested query param "asset"/, fn ->
        HmacRecipe.sign(request, @credentials, %{
          sign_recipe: @binance_recipes,
          sign_recipe_section: "sapi",
          timestamp: "1700000000000"
        })
      end
    end

    test "full recipe maps fall back to the top-level section segment" do
      request = %{
        method: :post,
        path: "/asset/dust",
        body: nil,
        params: %{"asset" => ["BTC", "USDT"]}
      }

      exact =
        HmacRecipe.sign(request, @credentials, %{
          sign_recipe: @binance_recipes,
          sign_recipe_section: "sapi",
          timestamp: "1700000000000"
        })

      dotted =
        HmacRecipe.sign(request, @credentials, %{
          sign_recipe: @binance_recipes,
          sign_recipe_section: "sapi.margin",
          timestamp: "1700000000000"
        })

      assert dotted == exact
    end

    test "full recipe maps fall back to heuristic resolution on an unknown section" do
      request = %{
        method: :post,
        path: "/asset/dust",
        body: nil,
        params: %{"asset" => ["BTC"]}
      }

      assert %SignedRequest{} =
               HmacRecipe.sign(request, @credentials, %{
                 sign_recipe: @binance_recipes,
                 sign_recipe_section: "unknown",
                 timestamp: "1700000000000"
               })
    end

    test "Binance JSON query arrays reject nested values" do
      component = %{"encoder" => "urlencodeJsonArray", "key_order" => "insertion", "source" => "query"}

      request = %{
        method: :get,
        path: "/api/v3/ticker/price",
        body: nil,
        params: [{"symbols", [%{"symbol" => "BTCUSDT"}]}]
      }

      assert_raise ArgumentError, ~r/unsupported nested query param "symbols"/, fn ->
        HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      end
    end

    test "plain urlencode expands scalar list params with empty-bracket keys" do
      component = %{"encoder" => "urlencode", "key_order" => "insertion", "source" => "query"}

      request = %{
        method: :get,
        path: "/private/get_order_margin_by_ids",
        body: nil,
        params: [{"ids", ["a", "b"]}, {"currency", "ETH"}]
      }

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      query = "ids%5B%5D=a&ids%5B%5D=b&currency=ETH"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "plain urlencode raises on nested list-of-maps naming the param" do
      component = %{"encoder" => "urlencode", "key_order" => "insertion", "source" => "query"}

      request = %{
        method: :get,
        path: "/private/execute_block_trade",
        body: nil,
        params: [{"trades", [%{"instrument_name" => "BTC-PERPETUAL"}]}]
      }

      assert_raise ArgumentError, ~r/unsupported nested query param "trades"/, fn ->
        HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      end
    end

    test "honors raw query encoding" do
      component = %{"encoder" => "rawencode", "key_order" => "insertion", "source" => "query"}
      request = %{method: :get, path: "/private", body: nil, params: [{"symbol", "BTC/USDT"}, {"note", "a b"}]}

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      query = "symbol=BTC/USDT&note=a b"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "honors nested query encoding" do
      component = %{"encoder" => "urlencodeNested", "key_order" => "insertion", "source" => "query"}

      request = %{
        method: :get,
        path: "/private",
        body: nil,
        params: [{"filter", %{"currency" => "BTC"}}, {"limit", 1}]
      }

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      query = "filter=%7B%22currency%22%3A%22BTC%22%7D&limit=1"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "treats nil query params as empty" do
      component = %{"encoder" => "urlencode", "key_order" => "insertion", "source" => "query"}
      request = %{method: :get, path: "/private", body: nil, params: nil}

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      signature = "" |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "ignores malformed replacement entries" do
      component = %{
        "encoder" => "urlencode",
        "key_order" => "insertion",
        "replacements" => [%{"from" => "%24", "to" => "$"}, %{"ignored" => true}],
        "source" => "query"
      }

      request = %{method: :get, path: "/private", body: nil, params: [{"symbol", "BTC$USDT"}]}

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(component)})
      query = "symbol=BTC$USDT"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "keeps legacy bare query components backward compatible" do
      request = %{method: :get, path: "/private", body: nil, params: [{"z", 1}, {"a", 2}]}

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: query_header_recipe(%{"source" => "query"})})
      query = "z=1&a=2"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "keeps wildcard legacy query components backward compatible" do
      request = %{method: :get, path: "/private", body: nil, params: [{"z", 1}, {"a", 2}]}
      recipe = query_header_recipe(%{"source" => "query"})
      recipe = Map.put(recipe, "canonical_string", %{"*" => recipe["canonical_string"]["GET"]})

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: recipe})
      query = "z=1&a=2"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "declared query auth params override caller-provided auth keys" do
      recipe =
        %{"encoder" => "urlencode", "key_order" => "sorted", "source" => "query"}
        |> query_header_recipe()
        |> Map.put("query_params", [
          %{"name" => "api_key", "source" => "api_key"},
          %{"name" => "account_type", "source" => "literal", "value" => "unified"},
          %{"name" => "recv_window", "source" => "recv_window"},
          %{"name" => "timestamp", "source" => "timestamp"}
        ])
        |> put_in(["signature_placement", "location"], "query")
        |> put_in(["signature_placement", "key"], "sign")

      request = %{
        method: :get,
        path: "/private",
        body: nil,
        params: [
          {"api_key", "caller-key"},
          {"recv_window", "1"},
          {"timestamp", "2"}
        ]
      }

      timestamp = "1700000000000"

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: recipe, timestamp: timestamp})

      query =
        "account_type=unified&api_key=#{@credentials.api_key}" <>
          "&recv_window=#{Defaults.recv_window_ms()}&timestamp=#{timestamp}"

      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query <> "&sign=" <> signature
    end

    test "bybit legacy_else GET overrides caller auth params in the signed query" do
      request = %{
        method: :get,
        path: "/user/v3/private/query-api",
        body: nil,
        params: %{"api_key" => "caller-key", "recv_window" => "1", "timestamp" => "2"}
      }

      timestamp = "1700000000000"
      recv = to_string(Defaults.recv_window_ms())

      signed =
        HmacRecipe.sign(request, @credentials, %{
          sign_recipe: @bybit_recipe,
          timestamp: timestamp
        })

      query = "api_key=#{@credentials.api_key}&recv_window=#{recv}&timestamp=#{timestamp}"
      expected = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query <> "&sign=" <> expected
      refute signed.url =~ "caller-key"
      refute signed.url =~ "timestamp=2"
      refute signed.url =~ "recv_window=1"
    end

    test "ignores malformed and unknown query auth declarations" do
      recipe =
        %{"encoder" => "urlencode", "key_order" => "sorted", "source" => "query"}
        |> query_header_recipe()
        |> Map.put("query_params", [
          %{"name" => "ignored", "source" => "unknown"},
          %{"source" => "api_key"}
        ])

      request = %{method: :get, path: "/private", body: nil, params: %{"z" => 1}}

      signed = HmacRecipe.sign(request, @credentials, %{sign_recipe: recipe})
      query = "z=1"
      signature = query |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert signed.url == request.path <> "?" <> query
      assert {"X-SIGNATURE", signature} in signed.headers
    end

    test "generates nonce from fallback when no override is configured" do
      recipe = %{
        "auth_headers" => [%{"name" => "X-NONCE", "source" => "nonce"}],
        "canonical_string" => %{"GET" => %{"components" => [%{"source" => "nonce"}]}},
        "crypto_op" => %{"algo" => "hmac_sha256"},
        "nonce" => %{"source" => "timestamp_ms", "format" => "string"},
        "pre_sign_transforms" => [%{"op" => "hex_encode", "target" => "signature"}],
        "signature_placement" => %{"key" => "X-SIGNATURE", "location" => "header"},
        "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
      }

      signed =
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe}
        )

      assert {"X-NONCE", nonce} = List.keyfind(signed.headers, "X-NONCE", 0)
      assert {nonce_int, ""} = Integer.parse(nonce)
      assert nonce_int > 0
    end

    test "preserves prebuilt body while signing body components" do
      request = %{
        method: :post,
        path: "/api/v5/trade/order",
        body: ~s({"side":"buy"}),
        params: %{"ignored" => "param"}
      }

      timestamp = "2026-06-14T12:34:56.789Z"
      config = %{sign_recipe: @recipe, timestamp: timestamp}

      signed = HmacRecipe.sign(request, @credentials, config)
      expected_signature = hmac_base64(timestamp <> "POST" <> request.path <> request.body)

      assert signed.body == request.body
      assert {"OK-ACCESS-SIGN", expected_signature} in signed.headers
    end

    test "supports nonce and recv-window canonical/header sources" do
      recipe = %{
        "auth_headers" => [
          %{"name" => "X-NONCE", "source" => "nonce"},
          %{"name" => "X-RECV-WINDOW", "source" => "recv_window"},
          %{"name" => "X-IGNORED", "source" => "ignored"}
        ],
        "canonical_string" => %{
          "GET" => %{
            "components" => [
              %{"source" => "api_key"},
              %{"source" => "passphrase"},
              %{"source" => "nonce"},
              %{"source" => "recv_window"}
            ]
          }
        },
        "crypto_op" => %{"algo" => "hmac_sha256"},
        "nonce" => %{"source" => "timestamp_ms", "format" => "string"},
        "pre_sign_transforms" => [%{"op" => "hex_encode", "target" => "signature"}],
        "signature_placement" => %{"key" => "X-SIGNATURE", "location" => "header"},
        "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
      }

      signed =
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe, nonce_override: @nonce_override}
        )

      nonce = to_string(@nonce_override)
      recv_window = to_string(Defaults.recv_window_ms())
      expected_payload = "api-key" <> "passphrase" <> nonce <> recv_window
      expected_signature = expected_payload |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert {"X-NONCE", nonce} in signed.headers
      assert {"X-RECV-WINDOW", recv_window} in signed.headers
      refute Enum.any?(signed.headers, &match?({"X-IGNORED", _value}, &1))
      assert {"X-SIGNATURE", expected_signature} in signed.headers
    end

    test "decodes base64 HMAC secrets when declared by the recipe" do
      secret = "decoded-secret"
      encoded_credentials = %{@credentials | secret: Base.encode64(secret)}

      recipe =
        "hmac_sha256"
        |> digest_recipe([])
        |> put_in(["crypto_op", "key_encoding"], "base64_decode")

      signed =
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          encoded_credentials,
          %{sign_recipe: recipe}
        )

      expected_signature =
        "payload"
        |> Signing.hmac_sha256(secret)
        |> Signing.encode_hex()

      assert {"X-SIGNATURE", expected_signature} in signed.headers
    end

    test "supports staged hash components in canonical payloads" do
      recipe = staged_digest_recipe("sha256", "hex")

      signed =
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe}
        )

      stage =
        "stage-payload"
        |> Signing.sha256()
        |> Signing.encode_hex()

      expected_signature = stage |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()
      assert {"X-SIGNATURE", expected_signature} in signed.headers
    end

    test "supports binary staged hashes" do
      recipe = staged_digest_recipe("sha512", "binary")

      signed =
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe}
        )

      stage = Signing.sha512("stage-payload")
      expected_signature = stage |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()

      assert {"X-SIGNATURE", expected_signature} in signed.headers
    end

    test "leaves unknown staged hash algorithms and encodings unchanged" do
      recipe = staged_digest_recipe("identity", "identity")

      signed =
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe}
        )

      expected_signature = "stage-payload" |> Signing.hmac_sha256(@credentials.secret) |> Signing.encode_hex()
      assert {"X-SIGNATURE", expected_signature} in signed.headers
    end

    test "supports SHA384 and default hex encoding" do
      recipe = digest_recipe("hmac_sha384", [])

      signed =
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe}
        )

      expected_signature =
        "payload"
        |> Signing.hmac_sha384(@credentials.secret)
        |> Signing.encode_hex()

      assert {"X-SIGNATURE", expected_signature} in signed.headers
    end

    test "supports SHA512 and url signature encoding" do
      recipe = digest_recipe("hmac_sha512", [%{"op" => "url_encode", "target" => "signature"}])

      signed =
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe}
        )

      expected_signature =
        "payload"
        |> Signing.hmac_sha512(@credentials.secret)
        |> Signing.encode_hex()
        |> URI.encode_www_form()

      assert {"X-SIGNATURE", expected_signature} in signed.headers
    end

    test "raises when canonical components are missing" do
      assert_raise ArgumentError, ~r/missing canonical_string components/, fn ->
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: %{"canonical_string" => %{}, "crypto_op" => %{"algo" => "hmac_sha256"}}}
        )
      end
    end

    test "raises on unsupported canonical component source" do
      recipe =
        "hmac_sha256"
        |> digest_recipe([])
        |> put_in(["canonical_string", "GET", "components"], [%{"source" => "unknown"}])

      assert_raise ArgumentError, ~r/unsupported sign_recipe canonical component source/, fn ->
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe}
        )
      end
    end

    test "raises on unsupported crypto operation" do
      recipe = digest_recipe("rsa_sha256", [])

      assert_raise ArgumentError, ~r/unsupported sign_recipe crypto_op algo/, fn ->
        HmacRecipe.sign(
          %{method: :get, path: "/private", body: nil, params: %{}},
          @credentials,
          %{sign_recipe: recipe}
        )
      end
    end
  end

  defp digest_recipe(algo, transforms) do
    %{
      "auth_headers" => [],
      "canonical_string" => %{
        "GET" => %{"components" => [%{"source" => "literal", "value" => "payload"}]}
      },
      "crypto_op" => %{"algo" => algo},
      "pre_sign_transforms" => transforms,
      "signature_placement" => %{"key" => "X-SIGNATURE", "location" => "header"},
      "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
    }
  end

  defp staged_digest_recipe(algo, output_encoding) do
    %{
      "auth_headers" => [],
      "canonical_string" => %{
        "GET" => %{
          "components" => [%{"source" => "stage", "stage" => "payload_hash"}],
          "stages" => [
            %{
              "algo" => algo,
              "components" => [%{"source" => "literal", "value" => "stage-payload"}],
              "name" => "payload_hash",
              "op" => "hash",
              "output_encoding" => output_encoding
            }
          ]
        }
      },
      "crypto_op" => %{"algo" => "hmac_sha256"},
      "pre_sign_transforms" => [%{"op" => "hex_encode", "target" => "signature"}],
      "signature_placement" => %{"key" => "X-SIGNATURE", "location" => "header"},
      "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
    }
  end

  defp query_header_recipe(component) do
    %{
      "auth_headers" => [],
      "canonical_string" => %{"GET" => %{"components" => [component]}},
      "crypto_op" => %{"algo" => "hmac_sha256"},
      "pre_sign_transforms" => [%{"op" => "hex_encode", "target" => "signature"}],
      "signature_placement" => %{"key" => "X-SIGNATURE", "location" => "header"},
      "timestamp" => %{"format" => "string", "source" => "timestamp_ms"}
    }
  end

  defp hmac_base64(payload) do
    payload
    |> Signing.hmac_sha256(@credentials.secret)
    |> Signing.encode_base64()
  end
end
