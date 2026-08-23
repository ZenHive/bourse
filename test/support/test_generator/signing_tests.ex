defmodule Bourse.Test.Generator.SigningTests do
  @moduledoc """
  Compile-time generator for per-exchange signing verification tests.

  Usage:

      defmodule Bourse.SigningVerificationTest do
        use ExUnit.Case, async: true
        use Bourse.Test.Generator.SigningTests
      end

  At compile time, iterates `Bourse.Registry.exchanges/0`, resolves each
  exchange's generated module, reads `__signing__/0`, and emits a
  `describe` block per exchange with 4 tests — basic sign, signature
  format, required headers, timestamp/nonce format.

  The first-party venue patterns `:hyperliquid`, `:derive`, and `:lighter` are
  skipped — they sign action/order
  payloads rather than HTTP query/header requests (and `:lighter` also requires
  an external helper process plus a real zk-Schnorr key), so they are covered by
  their dedicated parity tests (run `mix ccxt.classify_signing` for the pattern
  list).

  All tests run offline with dummy credentials, tagged `:signing`.
  """

  alias Bourse.Registry
  alias Bourse.Test.Generator.TagAtoms

  defmacro __using__(_opts) do
    exchanges = collect_exchanges()

    test_blocks =
      for {exchange_id, module, pattern} <- exchanges do
        build_describe(exchange_id, module, pattern)
      end

    quote do
      alias Bourse.Test.Generator.SignatureHelper

      # Shared dummy credentials for supported generic HTTP patterns.
      @dummy_credentials %Bourse.Credentials{
        api_key: "test-api-key-12345",
        secret: "dGVzdHNlY3JldGJ5dGVzZm9yc2lnbmluZ3Rlc3QxMjM0NTY=",
        password: "test-passphrase",
        uid: "42"
      }

      unquote_splicing(test_blocks)
    end
  end

  # Collected at compile time so the per-exchange lists baked in below
  # reflect the current Registry + classifier output.
  defp collect_exchanges do
    Registry.exchanges()
    |> Enum.map(fn id ->
      module = Registry.module_for(id)
      pattern = if module, do: fetch_pattern(module)
      {id, module, pattern}
    end)
    |> Enum.filter(fn {_id, module, pattern} ->
      module != nil and pattern != nil and pattern not in skipped_patterns()
    end)
  end

  # The DEX patterns sign action/order payloads, not generic HTTP requests, and
  # are covered by their dedicated parity tests.
  # `:lighter` additionally needs an external OS helper process and a real
  # 40-byte zk-Schnorr key, neither of which these dummy-credential offline
  # tests provide; it is covered by test/bourse/signing/lighter_test.exs and the
  # `:native` C-ABI test instead.
  defp skipped_patterns, do: [:hyperliquid, :derive, :lighter]

  defp fetch_pattern(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__signing__, 0) do
      Map.get(module.__signing__(), :pattern)
    end
  end

  defp build_describe(exchange_id, module, pattern) do
    tag_atom = TagAtoms.exchange_tag!(exchange_id)

    quote do
      describe "signing (#{unquote(exchange_id)} / #{unquote(pattern)})" do
        @describetag :signing
        @describetag unquote(tag_atom)

        test "sign/4 produces headers and URL" do
          %{pattern: pattern, config: config} = unquote(module).__signing__()

          path = SignatureHelper.branch_path(config, "/api/v1/account")
          request = %{method: :get, path: path, params: %{}, body: nil}
          signed = Bourse.Signing.sign(pattern, request, @dummy_credentials, config)

          assert is_list(signed.headers), "headers should be a list"
          assert is_binary(signed.url), "url should be a string"
        end

        test "signature format matches #{unquote(pattern)}" do
          %{pattern: pattern, config: config} = unquote(module).__signing__()

          request = %{
            method: :post,
            path: SignatureHelper.branch_path(config, "/api/v1/order"),
            params: %{symbol: "BTCUSDT", side: "buy", type: "limit", quantity: 0.001, price: 50_000},
            body: nil
          }

          signed = Bourse.Signing.sign(pattern, request, @dummy_credentials, config)
          SignatureHelper.validate_signature_for_pattern(signed, config, pattern)
        end

        test "required headers present for #{unquote(pattern)}" do
          %{pattern: pattern, config: config} = unquote(module).__signing__()

          path = SignatureHelper.branch_path(config, "/api/v1/account")
          request = %{method: :get, path: path, params: %{}, body: nil}
          signed = Bourse.Signing.sign(pattern, request, @dummy_credentials, config)
          headers_map = Map.new(signed.headers)

          SignatureHelper.validate_required_headers(headers_map, config, pattern)
        end

        test "timestamp/nonce format for #{unquote(pattern)}" do
          %{pattern: pattern, config: config} = unquote(module).__signing__()

          path = SignatureHelper.branch_path(config, "/api/v1/time")
          request = %{method: :get, path: path, params: %{}, body: nil}
          signed = Bourse.Signing.sign(pattern, request, @dummy_credentials, config)
          headers_map = Map.new(signed.headers)

          SignatureHelper.validate_timestamp_format(headers_map, signed, config, pattern)
        end
      end
    end
  end
end
