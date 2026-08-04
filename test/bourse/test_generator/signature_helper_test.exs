defmodule Bourse.Test.Generator.SignatureHelperTest do
  use ExUnit.Case, async: true

  alias Bourse.Test.Generator.SignatureHelper

  describe "validate_required_headers/3 authored header names" do
    test "resolves X-BAPI headers from Bybit's owned recipe" do
      signing = Bourse.Bybit.__signing__().config

      headers_map = %{
        "X-BAPI-API-KEY" => "k",
        "X-BAPI-TIMESTAMP" => "1781672802412",
        "X-BAPI-SIGN" => "sig"
      }

      assert :ok = SignatureHelper.validate_required_headers(headers_map, signing, :hmac_sha256_headers)
    end

    test "resolves OK-ACCESS headers from OKX's owned recipe" do
      signing = Bourse.Okx.__signing__().config

      headers_map = %{
        "OK-ACCESS-KEY" => "k",
        "OK-ACCESS-TIMESTAMP" => "2026-07-25T00:00:00.000Z",
        "OK-ACCESS-SIGN" => "sig",
        "OK-ACCESS-PASSPHRASE" => "p"
      }

      assert :ok =
               SignatureHelper.validate_required_headers(
                 headers_map,
                 signing,
                 :hmac_sha256_iso_passphrase
               )
    end

    test "header-name mismatch fails instead of accepting family defaults" do
      signing = Bourse.Okx.__signing__().config

      headers_map = %{
        "X-BAPI-API-KEY" => "k",
        "X-BAPI-TIMESTAMP" => "1781672802412",
        "X-BAPI-SIGN" => "sig"
      }

      assert_raise ExUnit.AssertionError, ~r/OK-ACCESS-KEY/, fn ->
        SignatureHelper.validate_required_headers(headers_map, signing, :hmac_sha256_iso_passphrase)
      end
    end
  end
end
