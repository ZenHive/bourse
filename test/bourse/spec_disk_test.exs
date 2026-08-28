defmodule Bourse.SpecDiskTest do
  @moduledoc """
  On-disk authored specs are endpoint-major; `Bourse.Spec.Disk` rotates them
  back into the facet-major map `Bourse.Spec.Schema` validates.

  `priv/venues/_shared/binance_family/rotation_report.json` is the record of
  the one-shot `spec.json` → endpoint-major migration; its `hashes` key set
  still pins the venue roster below, but the hash values themselves are a
  historical artifact, not a live guarantee.
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

  # The hash-pin test that lived here proved the endpoint-major split reproduced the
  # pre-migration facet-major maps; that migration proof is discharged, and the digest
  # legitimately changes on every authored edit. The structural test above is the
  # standing invariant.

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
    shared = JsonDocument.decode_file!("priv/venues/_shared/binance_family/descriptors.json")

    assembled = Spec.load!("binance")
    descriptor = assembled["endpoints"]["descriptors"]["addMargin"]
    refute Map.has_key?(descriptor, "$ref")
    assert descriptor["name"] == "addMargin"
    assert descriptor == shared["addMargin"]

    for {method, obj} <- on_disk do
      case obj["descriptor"] do
        %{"$ref" => "binance_family#" <> key} ->
          assert assembled["endpoints"]["descriptors"][method] == shared[key]

        _other ->
          :ok
      end
    end

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
end
