defmodule Bourse.Extract.JsonLoaderTest do
  use ExUnit.Case, async: true

  alias Bourse.Extract.EmulatedMethods
  alias Bourse.Extract.JsonLoader

  @fixture_dir Path.expand("../../fixtures/extractor", __DIR__)

  describe "duplicate-key rejection through the JsonLoader path" do
    test "rejects a duplicate key naming file, key, and object path" do
      path = Path.join(@fixture_dir, "duplicate_key.json")

      error = assert_raise ArgumentError, fn -> JsonLoader.decode_file!(path) end

      assert error.message =~ path
      assert error.message =~ ~s(duplicate key "hyperliquid")
      assert error.message =~ "object path $.emulated_methods"
    end

    test "leaves malformed JSON to Jason so the decode error keeps its position" do
      path = Path.join(System.tmp_dir!(), "extractor-malformed-#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"emulated_methods": }))
      on_exit(fn -> File.rm(path) end)

      # Shared decoder re-parses with `:json`, which reports malformed input as an
      # opaque `{:invalid_byte, _}` — it must not mask this for JsonLoader either.
      assert_raise Jason.DecodeError, fn -> JsonLoader.decode_file!(path) end
    end

    test "validates every extractor document currently on disk" do
      documents = Path.wildcard(Path.expand("../../../priv/extractor/*.json", __DIR__))

      # Without this, an empty glob would let the catalog check pass vacuously.
      assert documents != []

      assert :ok = JsonLoader.validate_all_documents!()
    end
  end

  describe "runtime emulation declarations" do
    test "EmulatedMethods reloads only the supported owned specs" do
      data = EmulatedMethods.reload!()

      assert data["emulated_methods"] |> Map.keys() |> Enum.sort() == Bourse.Spec.exchanges()
      refute Map.has_key?(data["emulated_methods"], "kraken")
    end
  end
end
