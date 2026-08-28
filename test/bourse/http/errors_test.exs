defmodule Bourse.HTTP.ErrorsTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.HTTP.Errors

  setup do
    exchange = %Exchange{
      id: "errors_test_#{System.unique_integer([:positive])}",
      name: "Errors Test",
      credentials: nil,
      sandbox: false,
      rate_limit_ms: 100,
      hostname: nil,
      base_urls: %{"public" => "https://api.test.com"},
      has: %{},
      required_credentials: %{},
      options: %{},
      error_codes: %{"10001" => :insufficient_funds},
      broad_error_patterns: %{"Insufficient balance!" => :insufficient_funds},
      error_body_checks: [],
      error_code_fields: ~w(code ret_code retCode error_code),
      error_handler_checks: [],
      status_map: %{},
      http_exceptions: %{"418" => :exchange_not_available},
      spec: %{}
    }

    {:ok, exchange: exchange}
  end

  describe "classify_response/5 success path" do
    test "returns decoded body on 200 JSON map", %{exchange: exchange} do
      body = %{"code" => 0, "result" => "ok"}

      assert {:ok, %{status: 200, body: ^body}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end

    test "decodes JSON string body when Content-Type is not json", %{exchange: exchange} do
      body = ~s({"code":0,"msg":"ok"})

      assert {:ok, %{body: %{"code" => 0, "msg" => "ok"}}} =
               Errors.classify_response(:get, 200, %{"content-type" => ["text/plain"]}, body, exchange)
    end

    test "leaves non-JSON binary body as-is on success", %{exchange: exchange} do
      assert {:ok, %{body: "not-json"}} =
               Errors.classify_response(:get, 200, %{}, "not-json", exchange)
    end

    test "204 with empty body is success", %{exchange: exchange} do
      assert {:ok, %{status: 204, body: ""}} =
               Errors.classify_response(:get, 204, %{}, "", exchange)
    end

    # Task 255: OKX private POSTs may succeed with HTTP 200 and an empty body.
    test "empty body on 200 is success", %{exchange: exchange} do
      assert {:ok, %{status: 200, body: ""}} =
               Errors.classify_response(:post, 200, %{}, "", exchange)
    end

    test "whitespace-only body on 200 is success", %{exchange: exchange} do
      assert {:ok, %{status: 200, body: "  "}} =
               Errors.classify_response(:get, 200, %{}, "  ", exchange)
    end
  end

  describe "classify_response/5 body-level errors" do
    test "maps exchange error codes", %{exchange: exchange} do
      body = %{"code" => "10001", "msg" => "no funds"}

      assert {:error, %Error{type: :insufficient_funds, code: "10001"}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end

    test "broad pattern matches message when code is unmapped", %{exchange: exchange} do
      body = %{"code" => "99999", "msg" => "Insufficient balance!"}

      assert {:error, %Error{type: :insufficient_funds}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end

    test "JSON-RPC error member is failure", %{exchange: exchange} do
      body = %{"jsonrpc" => "2.0", "error" => %{"code" => -1, "message" => "bad"}, "id" => 1}

      assert {:error, %Error{}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end

    test "JSON-RPC result without error is success", %{exchange: exchange} do
      body = %{"jsonrpc" => "2.0", "result" => [1], "id" => 1}

      assert {:ok, %{body: ^body}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end

    test "lighter-style code 200 is success", %{exchange: exchange} do
      body = %{"code" => 200, "data" => []}

      assert {:ok, %{body: ^body}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end

    test "sentinel-only === match is error", %{exchange: exchange} do
      check = %{
        field: "status",
        field2: "",
        roles: [:status_sentinel],
        sentinel_values: [%{operator: "===", value: "err"}]
      }

      exchange = %{exchange | error_body_checks: [check], error_code_fields: []}
      body = %{"status" => "err"}

      assert {:error, %Error{}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end

    test "code-role sentinel success value suppresses heuristic", %{exchange: exchange} do
      check = %{
        field: "code",
        field2: "",
        roles: [:status_sentinel, :error_code],
        sentinel_values: [%{operator: "===", value: "200000"}]
      }

      exchange = %{
        exchange
        | error_body_checks: [check],
          error_code_fields: ["code"],
          error_codes: %{}
      }

      body = %{"code" => "200000", "msg" => "success"}

      assert {:ok, %{body: ^body}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end

    test "inequality sentinel treats matching value as success", %{exchange: exchange} do
      check = %{
        field: "retCode",
        field2: "",
        roles: [:status_sentinel],
        sentinel_values: [%{operator: "!==", value: "0"}]
      }

      # retCode "0" is in the !== success set → success; non-matching falls to error path
      exchange = %{exchange | error_body_checks: [check], error_code_fields: []}

      assert {:ok, _} =
               Errors.classify_response(:get, 200, %{}, %{"retCode" => "0"}, exchange)

      assert {:error, _} =
               Errors.classify_response(:get, 200, %{}, %{"retCode" => "1"}, exchange)
    end

    test "field2 is used when primary field is missing", %{exchange: exchange} do
      check = %{
        field: "missing",
        field2: "status",
        roles: [:status_sentinel],
        sentinel_values: [%{operator: "===", value: "err"}]
      }

      exchange = %{exchange | error_body_checks: [check], error_code_fields: []}

      assert {:error, _} =
               Errors.classify_response(:get, 200, %{}, %{"status" => "err"}, exchange)
    end

    test "integer and atom sentinel values compare as strings", %{exchange: exchange} do
      check = %{
        field: "code",
        field2: "",
        roles: [:status_sentinel],
        sentinel_values: [%{operator: "===", value: "7"}]
      }

      exchange = %{exchange | error_body_checks: [check], error_code_fields: []}

      assert {:error, _} =
               Errors.classify_response(:get, 200, %{}, %{"code" => 7}, exchange)
    end
  end

  describe "classify_response/5 HTTP status errors" do
    test "429 is rate_limit_exceeded with retry_after ms", %{exchange: exchange} do
      body = %{"message" => "slow down", "retry_after" => 2}

      assert {:error, %Error{type: :rate_limit_exceeded, retry_after: 2000, http_status: 429}} =
               Errors.classify_response(:get, 429, %{}, body, exchange)
    end

    test "401/403 are authentication_error", %{exchange: exchange} do
      assert {:error, %Error{type: :authentication_error, http_status: 401}} =
               Errors.classify_response(:get, 401, %{}, %{"message" => "nope"}, exchange)

      assert {:error, %Error{type: :authentication_error, http_status: 403}} =
               Errors.classify_response(:get, 403, %{}, "forbidden", exchange)
    end

    test "401/403 keep the venue error code from the body", %{exchange: exchange} do
      # OKX answers a permission failure with HTTP 401 and its own code "50120".
      # The auth status must not discard that code (task 432 live evidence).
      body = %{"code" => "50120", "msg" => "This API key doesn't have permission to use this function"}

      assert {:error, %Error{type: :authentication_error, code: "50120", http_status: 401}} =
               Errors.classify_response(:post, 401, %{}, body, exchange)
    end

    test "401/403 with a non-map body leave the code nil", %{exchange: exchange} do
      assert {:error, %Error{type: :authentication_error, code: nil, http_status: 403}} =
               Errors.classify_response(:get, 403, %{}, "forbidden", exchange)
    end

    test "status_map and http_exceptions classify typed errors", %{exchange: exchange} do
      exchange = %{exchange | status_map: %{"503" => :exchange_not_available}}

      assert {:error, %Error{type: :exchange_not_available, http_status: 503}} =
               Errors.classify_response(:get, 503, %{}, %{"msg" => "down"}, exchange)

      assert {:error, %Error{type: :exchange_not_available, http_status: 418}} =
               Errors.classify_response(:get, 418, %{}, %{"msg" => "teapot"}, exchange)
    end

    test "error_handler_checks match status guard and body contains", %{exchange: exchange} do
      exchange = %{
        exchange
        | error_handler_checks: [
            %{
              status_guard: {:gte, 400},
              body_contains: ["IP ban"],
              error_type: :rate_limit_exceeded
            }
          ]
      }

      body = %{"msg" => "IP ban active"}

      assert {:error, %Error{type: :rate_limit_exceeded, http_status: 418}} =
               Errors.classify_response(:get, 418, %{}, body, exchange)
    end

    test "error_handler :in status guard", %{exchange: exchange} do
      exchange = %{
        exchange
        | error_handler_checks: [
            %{
              status_guard: {:in, [451, 452]},
              body_contains: ["geo"],
              error_type: :access_restricted
            }
          ],
          http_exceptions: %{}
      }

      assert {:error, %Error{type: :access_restricted}} =
               Errors.classify_response(:get, 451, %{}, %{"msg" => "geo blocked"}, exchange)
    end

    test "binary body non-2xx becomes exchange_error", %{exchange: exchange} do
      assert {:error, %Error{type: :exchange_error, message: "raw fail", http_status: 500}} =
               Errors.classify_response(:get, 500, %{}, "raw fail", exchange)
    end

    test "non-string message values are inspected", %{exchange: exchange} do
      body = %{"message" => %{"nested" => true}, "code" => "10001"}

      assert {:error, %Error{type: :insufficient_funds, message: message}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)

      assert message =~ "nested"
    end
  end

  describe "classify_response/5 HTML" do
    test "content-type text/html is access_restricted", %{exchange: exchange} do
      headers = %{"content-type" => ["text/html; charset=utf-8"]}
      body = "<html><title>Blocked</title></html>"

      assert {:error, %Error{type: :access_restricted, message: message}} =
               Errors.classify_response(:get, 200, headers, body, exchange)

      assert message =~ "Blocked"
    end

    test "Cloudflare title is cloudflare_challenge", %{exchange: exchange} do
      body = "<html><title>Just a moment...</title><body>cf-chl-bypass</body></html>"

      assert {:error, %Error{type: :cloudflare_challenge}} =
               Errors.classify_response(:get, 403, %{}, body, exchange)
    end

    test "Attention Required title is cloudflare_challenge", %{exchange: exchange} do
      body = "<html><title>Attention Required!</title></html>"

      assert {:error, %Error{type: :cloudflare_challenge}} =
               Errors.classify_response(:get, 403, %{}, body, exchange)
    end

    test "HTML with status 401 is authentication_error (task 439)", %{exchange: exchange} do
      headers = %{"content-type" => ["text/html"]}
      body = "<html><head><title>401 Authorization Required</title></head><body>nginx</body></html>"

      assert {:error, %Error{type: :authentication_error, code: 401, message: message, raw: raw}} =
               Errors.classify_response(:get, 401, headers, body, exchange)

      assert message =~ "401 Authorization Required"
      assert is_binary(raw[:body_preview])
    end

    test "HTML with status 403 stays access_restricted (task 439)", %{exchange: exchange} do
      headers = %{"content-type" => ["text/html"]}
      body = "<html><head><title>Forbidden</title></head><body>blocked</body></html>"

      assert {:error, %Error{type: :access_restricted, code: 403}} =
               Errors.classify_response(:get, 403, headers, body, exchange)
    end

    test "Cloudflare markers win over status 401 (task 439)", %{exchange: exchange} do
      body = "<html><title>Just a moment...</title><body>cf-chl-bypass</body></html>"

      assert {:error, %Error{type: :cloudflare_challenge}} =
               Errors.classify_response(:get, 401, %{}, body, exchange)
    end

    test "HTML without title uses default messages", %{exchange: exchange} do
      body = "<!DOCTYPE html><html><body>no title</body></html>"

      assert {:error, %Error{type: :access_restricted, message: "Received HTML instead of JSON API response"}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end

    test "Cloudflare challenge without title uses default CF message", %{exchange: exchange} do
      body = "<html><body>cf-browser-verification</body></html>"

      assert {:error, %Error{type: :cloudflare_challenge, message: message}} =
               Errors.classify_response(:get, 403, %{}, body, exchange)

      assert message =~ "Cloudflare challenge page received"
    end
  end

  describe "classify_response/5 edge coverage" do
    test "invalid JSON-looking binary is left as body on success", %{exchange: exchange} do
      body = "{not-valid-json"

      assert {:ok, %{body: "{not-valid-json"}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end

    test "JSON array body is decoded", %{exchange: exchange} do
      assert {:ok, %{body: [1, 2]}} =
               Errors.classify_response(:get, 200, %{}, "[1,2]", exchange)
    end

    test "non-binary non-map body passes through ensure_json_decoded", %{exchange: exchange} do
      assert {:ok, %{body: 42}} =
               Errors.classify_response(:get, 200, %{}, 42, exchange)
    end

    test "string code \"200\" is success", %{exchange: exchange} do
      assert {:ok, %{body: %{"code" => "200"}}} =
               Errors.classify_response(:get, 200, %{}, %{"code" => "200"}, exchange)
    end

    test "string code OK is success", %{exchange: exchange} do
      assert {:ok, %{body: %{"code" => "OK"}}} =
               Errors.classify_response(:get, 200, %{}, %{"code" => "OK"}, exchange)
    end

    test "non-scalar code values are not treated as error codes", %{exchange: exchange} do
      body = %{"code" => %{"nested" => true}}

      assert {:ok, %{body: ^body}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end

    test "prefer_error_candidate upgrades to a known error code", %{exchange: exchange} do
      # First sentinel matches "x" (unknown code); second matches known "10001".
      checks = [
        %{
          field: "a",
          field2: "",
          roles: [:status_sentinel],
          sentinel_values: [%{operator: "===", value: "x"}]
        },
        %{
          field: "b",
          field2: "",
          roles: [:status_sentinel],
          sentinel_values: [%{operator: "===", value: "10001"}]
        }
      ]

      exchange = %{
        exchange
        | error_body_checks: checks,
          error_code_fields: [],
          error_codes: %{"10001" => :insufficient_funds}
      }

      assert {:error, %Error{type: :insufficient_funds, code: "10001"}} =
               Errors.classify_response(:get, 200, %{}, %{"a" => "x", "b" => "10001"}, exchange)
    end

    test "atom sentinel value is comparable", %{exchange: exchange} do
      check = %{
        field: "status",
        field2: "",
        roles: [:status_sentinel],
        sentinel_values: [%{operator: "===", value: "err"}]
      }

      exchange = %{exchange | error_body_checks: [check], error_code_fields: []}

      assert {:error, _} =
               Errors.classify_response(:get, 200, %{}, %{"status" => :err}, exchange)
    end

    test "non-comparable sentinel value is ignored", %{exchange: exchange} do
      check = %{
        field: "status",
        field2: "",
        roles: [:status_sentinel],
        sentinel_values: [%{operator: "===", value: "err"}]
      }

      exchange = %{exchange | error_body_checks: [check], error_code_fields: []}

      assert {:ok, _} =
               Errors.classify_response(:get, 200, %{}, %{"status" => %{"nested" => true}}, exchange)
    end

    test "keeps first known error when later candidate is also known", %{exchange: exchange} do
      checks = [
        %{
          field: "a",
          field2: "",
          roles: [:status_sentinel],
          sentinel_values: [%{operator: "===", value: "10001"}]
        },
        %{
          field: "b",
          field2: "",
          roles: [:status_sentinel],
          sentinel_values: [%{operator: "===", value: "10002"}]
        }
      ]

      exchange = %{
        exchange
        | error_body_checks: checks,
          error_codes: %{"10001" => :insufficient_funds, "10002" => :order_not_found}
      }

      assert {:error, %Error{type: :insufficient_funds, code: "10001"}} =
               Errors.classify_response(:get, 200, %{}, %{"a" => "10001", "b" => "10002"}, exchange)
    end

    test "nil error_handler_checks does not crash", %{exchange: exchange} do
      exchange = %{exchange | error_handler_checks: nil, http_exceptions: %{}}

      assert {:error, %Error{type: :exchange_error, http_status: 500}} =
               Errors.classify_response(:get, 500, %{}, %{"msg" => "x"}, exchange)
    end

    test "unknown status_guard does not match handler", %{exchange: exchange} do
      exchange = %{
        exchange
        | error_handler_checks: [
            %{status_guard: :always, body_contains: ["x"], error_type: :bad_request}
          ],
          http_exceptions: %{}
      }

      assert {:error, %Error{type: :exchange_error}} =
               Errors.classify_response(:get, 400, %{}, %{"msg" => "x"}, exchange)
    end

    test "non-list body_contains fails the handler match", %{exchange: exchange} do
      exchange = %{
        exchange
        | error_handler_checks: [
            %{status_guard: {:gte, 400}, body_contains: "not-a-list", error_type: :bad_request}
          ],
          http_exceptions: %{}
      }

      assert {:error, %Error{type: :exchange_error}} =
               Errors.classify_response(:get, 400, %{}, %{"msg" => "x"}, exchange)
    end

    test "retry_after absent or non-integer yields nil", %{exchange: exchange} do
      assert {:error, %Error{type: :rate_limit_exceeded, retry_after: nil}} =
               Errors.classify_response(:get, 429, %{}, %{"message" => "wait", "retry_after" => "soon"}, exchange)

      assert {:error, %Error{type: :rate_limit_exceeded, retry_after: nil}} =
               Errors.classify_response(:get, 429, %{}, "too many", exchange)
    end

    test "unknown error type falls back to exchange_error factory", %{exchange: exchange} do
      exchange = %{exchange | error_codes: %{"9" => :some_custom_type}}

      assert {:error, %Error{type: :exchange_error, code: "9"}} =
               Errors.classify_response(:get, 200, %{}, %{"code" => "9", "msg" => "x"}, exchange)
    end

    test "list body is not body-error scanned", %{exchange: exchange} do
      assert {:ok, %{body: [1, 2, 3]}} =
               Errors.classify_response(:get, 200, %{}, [1, 2, 3], exchange)
    end

    test "non-map non-binary message extraction path via non-2xx", %{exchange: exchange} do
      assert {:error, %Error{message: "Unknown error", http_status: 502}} =
               Errors.classify_response(:get, 502, %{}, nil, exchange)
    end

    test "code-role eq mismatch becomes error when value is known error", %{exchange: exchange} do
      check = %{
        field: "code",
        field2: "",
        roles: [:status_sentinel, :error_code],
        sentinel_values: [%{operator: "===", value: "0"}]
      }

      exchange = %{
        exchange
        | error_body_checks: [check],
          error_code_fields: ["code"],
          error_codes: %{"10001" => :insufficient_funds}
      }

      assert {:error, %Error{type: :insufficient_funds}} =
               Errors.classify_response(:get, 200, %{}, %{"code" => "10001", "msg" => "x"}, exchange)
    end
  end

  # ===========================================================================
  # Task 255 — HTTP error/success-body robustness
  # ===========================================================================

  describe "task 255 scalar gateway error envelopes" do
    test "scalar top-level error does not crash; typed error with http_status and raw", %{
      exchange: exchange
    } do
      # Recorded gateway-style envelope (OKX books-lite / books-sbe path).
      body = %{
        "timestamp" => "2026-07-16T12:00:00.000Z",
        "status" => 404,
        "error" => "Not Found",
        "requestId" => "req-scalar-error-fixture"
      }

      assert {:error, %Error{} = err} =
               Errors.classify_response(:get, 404, %{}, body, exchange)

      refute err.type == :network_error
      assert err.http_status == 404
      assert err.message == "Not Found"
      assert err.raw == body
    end

    test "scalar error with top-level code field still extracts code", %{exchange: exchange} do
      body = %{"error" => "bad request", "code" => "51000", "msg" => "Parameter timeOut error"}

      assert {:error, %Error{code: "51000", message: "Parameter timeOut error", raw: ^body}} =
               Errors.classify_response(:post, 400, %{}, body, exchange)
    end
  end

  describe "task 255 error detail fidelity" do
    test "okx batch-error envelope types from data[].sCode, not the outer code", %{exchange: exchange} do
      body = %{
        "code" => "1",
        "msg" => "All operations failed",
        "data" => [
          %{"algoId" => "a1", "sCode" => "51400", "sMsg" => "Cancellation failed as order is already canceled"},
          %{"algoId" => "a2", "sCode" => "0", "sMsg" => ""}
        ]
      }

      assert {:error, %Error{code: "51400", raw: ^body} = err} =
               Errors.classify_response(:post, 200, %{}, body, exchange)

      assert err.message == "Cancellation failed as order is already canceled"
      assert is_list(err.raw["data"])
      assert hd(err.raw["data"])["sCode"] == "51400"
    end

    test "okx batch 51400 classifies as order_not_found on the live error map" do
      exchange = Exchange.new!("okx")

      body = %{
        "code" => "1",
        "msg" => "All operations failed",
        "data" => [
          %{
            "sCode" => "51400",
            "sMsg" => "Order cancellation failed as the order has been filled, canceled or does not exist."
          }
        ]
      }

      assert {:error, %Error{type: :order_not_found, code: "51400"} = err} =
               Errors.classify_response(:post, 200, %{}, body, exchange)

      assert err.message =~ "does not exist"
    end

    test "okx batch 51121 classifies as invalid_order on the live error map" do
      exchange = Exchange.new!("okx")

      body = %{
        "code" => "1",
        "msg" => "All operations failed",
        "data" => [
          %{"sCode" => "51121", "sMsg" => "Order quantity must be a multiple of the lot size."}
        ]
      }

      assert {:error,
              %Error{type: :invalid_order, code: "51121", message: "Order quantity must be a multiple of the lot size."}} =
               Errors.classify_response(:post, 200, %{}, body, exchange)
    end

    test "non-JSON error body text is retained as message and raw", %{exchange: exchange} do
      body = "Method Not Allowed"

      assert {:error,
              %Error{type: :exchange_error, message: "Method Not Allowed", raw: "Method Not Allowed", http_status: 405}} =
               Errors.classify_response(:post, 405, %{}, body, exchange)
    end
  end

  describe "task 255 rfq_cancel_all_after 51000 JSON-string body" do
    # Root cause: non-2xx path skipped ensure_json_decoded/1, so a binary JSON body
    # hit normalize_error's non-map clause → code: nil and the raw JSON as message.
    test "binary JSON 51000 body parses code and message on non-2xx", %{exchange: exchange} do
      body = ~s({"code":"51000","msg":"Parameter timeOut error"})

      assert {:error, %Error{code: "51000", message: "Parameter timeOut error", http_status: 400} = err} =
               Errors.classify_response(:post, 400, %{}, body, exchange)

      assert is_map(err.raw)
      assert err.raw["code"] == "51000"
    end

    test "binary JSON 51000 body parses on HTTP 200 body-level error path", %{exchange: exchange} do
      body = ~s({"code":"51000","msg":"Parameter timeOut error"})

      assert {:error, %Error{code: "51000", message: "Parameter timeOut error", raw: %{"code" => "51000"}}} =
               Errors.classify_response(:post, 200, %{}, body, exchange)
    end
  end

  describe "task 255 body-level errors retain raw" do
    test "mapped body-level error includes raw body", %{exchange: exchange} do
      body = %{"code" => "10001", "msg" => "no funds"}

      assert {:error, %Error{type: :insufficient_funds, raw: ^body}} =
               Errors.classify_response(:get, 200, %{}, body, exchange)
    end
  end
end
