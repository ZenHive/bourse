defmodule Bourse.SpecDiskTest do
  @moduledoc """
  On-disk authored specs are endpoint-major; `Bourse.Spec.Disk` rotates them
  back into the facet-major map `Bourse.Spec.Schema` validates.

  Hashes in `priv/venues/_shared/binance_family/rotation_report.json` are the
  SHA-256 of the original facet-major maps (key-sorted Jason-canonical JSON),
  recorded before `spec.json` was deleted.
  """

  use ExUnit.Case, async: true

  alias Bourse.JsonDocument
  alias Bourse.Spec
  alias Bourse.Spec.Disk
  alias Bourse.Spec.Schema

  @report_path Path.expand("../../priv/venues/_shared/binance_family/rotation_report.json", __DIR__)
  @external_resource @report_path
  @report JsonDocument.decode_file!(@report_path)
  @hashes @report["hashes"]
  @split_files Disk.file_names()
  @binance_family ~w(binance binancecoinm binanceusdm)

  for venue <- Spec.exchanges(), file <- Spec.source_files(venue) do
    @external_resource file
  end

  test "every runtime venue is split endpoint-major and has no leftover spec.json" do
    assert Spec.exchanges() == Enum.sort(Map.keys(@hashes))

    for venue <- Spec.exchanges() do
      dir = Spec.authored_dir(venue)
      refute File.exists?(Path.join(dir, "spec.json")), "#{venue} still has spec.json"

      for name <- @split_files do
        assert File.exists?(Path.join(dir, name)), "#{venue} missing #{name}"
      end

      endpoints = JsonDocument.decode_file!(Path.join(dir, "endpoints.json"))
      venue_doc = JsonDocument.decode_file!(Path.join(dir, "venue.json"))
      raw = JsonDocument.decode_file!(Path.join(dir, "raw.json"))

      refute Map.has_key?(venue_doc, "endpoints")
      refute Map.has_key?(venue_doc, "errors")
      refute Map.has_key?(venue_doc, "markets")
      refute Map.has_key?(venue_doc, "normalization")

      Enum.each(endpoints, fn {method, obj} ->
        assert is_map(obj), "#{venue} #{method} is not an object"
        assert Map.has_key?(obj, "unified")
        assert Map.has_key?(obj, "mapping_complete")
        assert Map.has_key?(obj, "verification")
      end)

      Enum.each(Map.fetch!(raw, "endpoints"), fn {key, obj} ->
        assert is_map(obj), "#{venue} raw #{key} is not an object"
        assert Map.has_key?(obj, "api") or Map.has_key?(obj, "rate_limit")
      end)
    end
  end

  test "assembled maps match the recorded original hashes for all eleven venues" do
    mismatches =
      Enum.flat_map(Spec.exchanges(), fn venue ->
        assembled = Spec.load!(venue)
        digest = canonical_digest(assembled)

        if digest == @hashes[venue] do
          []
        else
          [{venue, digest, @hashes[venue]}]
        end
      end)

    assert mismatches == []
  end

  test "Schema still raises on a missing required slot after reassembly" do
    files = split_files("deribit")
    files = update_in(files["venue.json"], &Map.delete(&1, "auth"))

    assert_raise ArgumentError, ~r/owned spec "deribit" gap auth: missing required slot/, fn ->
      files
      |> Disk.assemble_maps("priv/venues")
      |> Schema.validate!("deribit")
    end
  end

  test "Schema still rejects forbidden slots after reassembly" do
    files = split_files("deribit")

    venue_files = update_in(files["venue.json"], &Map.put(&1, "ccxt_version", "forbidden"))

    assert_raise ArgumentError, ~r/gap ccxt_version: field is forbidden/, fn ->
      venue_files
      |> Disk.assemble_maps("priv/venues")
      |> Schema.validate!("deribit")
    end

    raw_files = update_in(files["raw.json"], &Map.put(&1, "class_info", %{}))

    assert_raise ArgumentError, ~r/gap raw.class_info: field is forbidden/, fn ->
      raw_files
      |> Disk.assemble_maps("priv/venues")
      |> Schema.validate!("deribit")
    end
  end

  test "binance-family descriptors are hoisted and resolved at assemble time" do
    on_disk = JsonDocument.decode_file!("priv/venues/binance/authored/endpoints.json")
    assert %{"$ref" => "binance_family#addMargin"} = on_disk["addMargin"]["descriptor"]

    assembled = Spec.load!("binance")
    descriptor = assembled["endpoints"]["descriptors"]["addMargin"]
    refute Map.has_key?(descriptor, "$ref")
    assert descriptor["name"] == "addMargin"

    shared = JsonDocument.decode_file!("priv/venues/_shared/binance_family/descriptors.json")
    assert map_size(shared) == @report["shared_descriptor_keys"]

    for venue <- @binance_family do
      files = Spec.source_files(venue)
      assert Enum.any?(files, &String.ends_with?(&1, "_shared/binance_family/descriptors.json"))
    end

    refute Enum.any?(Spec.source_files("deribit"), &String.contains?(&1, "_shared"))
  end

  test "a missing shared descriptor key fails loudly" do
    spec_root = copy_authored_tree()
    path = Path.join([spec_root, "binance", "authored", "endpoints.json"])
    endpoints = JsonDocument.decode_file!(path)

    endpoints =
      put_in(endpoints, ["addMargin", "descriptor", "$ref"], "binance_family#does_not_exist")

    File.write!(path, Jason.encode!(endpoints))

    assert_raise ArgumentError, ~r/shared descriptor "binance_family#does_not_exist"/, fn ->
      Spec.load_from_root!(spec_root, "binance")
    end
  end

  test "an invalid descriptor ref fails loudly" do
    spec_root = copy_authored_tree()
    path = Path.join([spec_root, "binance", "authored", "endpoints.json"])
    endpoints = JsonDocument.decode_file!(path)
    endpoints = put_in(endpoints, ["addMargin", "descriptor", "$ref"], "not-a-ref")
    File.write!(path, Jason.encode!(endpoints))

    assert_raise ArgumentError, ~r/invalid shared descriptor ref/, fn ->
      Spec.load_from_root!(spec_root, "binance")
    end
  end

  test "deribit fetchPositions is one contiguous endpoint object" do
    endpoints = JsonDocument.decode_file!("priv/venues/deribit/authored/endpoints.json")
    obj = Map.fetch!(endpoints, "fetchPositions")

    assert obj["unified"] == ["privateGetGetPositions"]
    assert obj["has"] == true
    assert obj["mapping_complete"] == true
    assert obj["verification"] == "verified"
    assert obj["parse"] == ["parsePositions"]
    assert obj["descriptor"]["name"] == "fetchPositions"
    assert obj["transaction_classification"] == %{"on_chain" => false, "transactional" => false}
    refute Map.has_key?(obj, "$ref")
  end

  defp copy_authored_tree do
    root = Path.join(System.tmp_dir!(), "spec-disk-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.cp_r!("priv/venues/_shared", Path.join(root, "_shared"))

    for venue <- Spec.exchanges() do
      dest = Path.join([root, venue, "authored"])
      File.mkdir_p!(dest)

      for name <- @split_files do
        File.cp!(Path.join(["priv/venues", venue, "authored", name]), Path.join(dest, name))
      end
    end

    root
  end

  defp split_files(venue) do
    Map.new(@split_files, fn name ->
      path = Path.join(["priv/venues", venue, "authored", name])
      {name, JsonDocument.decode_file!(path)}
    end)
  end

  defp canonical_digest(value) do
    value
    |> canonical()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_intersperse(",", fn {key, value} -> [Jason.encode!(key), ":", canonical(value)] end)

    IO.iodata_to_binary(["{", inner, "}"])
  end

  defp canonical(list) when is_list(list) do
    inner = Enum.map_intersperse(list, ",", &canonical/1)
    IO.iodata_to_binary(["[", inner, "]"])
  end

  defp canonical(other), do: Jason.encode!(other)
end
