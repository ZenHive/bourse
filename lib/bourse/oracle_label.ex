defmodule Bourse.OracleLabel do
  @moduledoc """
  Formats reality-oracle labels for recordings and accepted requests.

  Labels are derived from committed reality manifests so every verification
  claim names the venue observation that supports it.
  """

  @doc """
  Reality tier-1 identity for one recording-manifest row.

  Sourced from the manifest's venue / method / capture_date / host / endpoint.
  """
  @spec tier1_identity(map()) :: String.t()
  def tier1_identity(%{} = recording) do
    format_tier1_identity(
      required_field(recording, "venue"),
      required_field(recording, "method"),
      capture_date(recording),
      Map.get(recording, "endpoint"),
      Map.get(recording, "host")
    )
  end

  @doc "Full oracle label for a recording-manifest row."
  @spec tier1_label(map()) :: String.t()
  def tier1_label(%{} = recording) do
    "Oracle: #{tier1_identity(recording)}"
  end

  @doc """
  Reality tier-1 identity from a fixture JSON map (exchange/method/captured_at).

  Requires the recording manifest to identify the fixture's oracle.
  """
  @spec tier1_identity_from_fixture(map(), map(), String.t()) :: String.t()
  def tier1_identity_from_fixture(fixture, manifest, manifest_identity)
      when is_map(fixture) and is_map(manifest) and is_binary(manifest_identity) do
    venue = fixture["exchange"] || fixture["venue"]
    method = fixture["method"]

    case recording_for(manifest, venue, method) do
      %{} = recording ->
        tier1_identity(recording)

      nil ->
        raise ArgumentError,
              "recording manifest #{manifest_identity} has no entry for #{venue}/#{method}"
    end
  end

  @doc "Full oracle label for a fixture JSON map."
  @spec tier1_label_from_fixture(map(), map(), String.t()) :: String.t()
  def tier1_label_from_fixture(fixture, manifest, manifest_identity) do
    "Oracle: #{tier1_identity_from_fixture(fixture, manifest, manifest_identity)}"
  end

  @doc """
  Suite banner for tier-1 tests, listing recording identities from the manifest.

  `paths` are relative fixture paths such as `deribit/fetch_markets.json`.
  """
  @spec tier1_suite_banner([String.t()], map(), String.t()) :: String.t()
  def tier1_suite_banner(paths, manifest, manifest_identity)
      when is_list(paths) and is_map(manifest) and is_binary(manifest_identity) do
    by_path = Map.new(manifest["recordings"] || [], &{&1["path"], &1})

    lines =
      paths
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn path ->
        case Map.get(by_path, path) do
          %{} = recording ->
            "  - #{tier1_identity(recording)}"

          nil ->
            raise ArgumentError,
                  "recording manifest #{manifest_identity} has no entry for #{path}"
        end
      end)

    Enum.join(
      [
        "Oracle: verified reality vs real-recordings corpus (#{manifest_identity})" | lines
      ],
      "\n"
    )
  end

  @doc "Labels a golden request as exchange-acceptance evidence."
  @spec exchange_acceptance_label(map()) :: String.t()
  def exchange_acceptance_label(%{} = golden) do
    acceptance = Map.get(golden, "acceptance", golden)
    venue = required_field(acceptance, "venue")
    method = required_field(acceptance, "method")
    endpoint = required_field(acceptance, "endpoint")
    host = required_field(acceptance, "host")
    date = capture_date(acceptance)
    status = Map.fetch!(acceptance, "http_status")
    success = required_field(acceptance, "business_success")

    "Oracle: exchange-acceptance tier 1 vs #{venue} #{method} accepted #{date} " <>
      "(#{endpoint} @ #{host}, HTTP #{status}, #{success})."
  end

  defp format_tier1_identity(venue, method, date, endpoint, host) do
    core = "reality tier 1 vs #{venue} #{method} captured #{date}"

    case {endpoint, host} do
      {ep, h} when is_binary(ep) and ep != "" and is_binary(h) and h != "" ->
        "#{core} (#{ep} @ #{h})"

      _other ->
        core
    end
  end

  defp capture_date(%{"capture_date" => date}) when is_binary(date) and date != "", do: date

  defp capture_date(%{"captured_at" => captured_at}) when is_binary(captured_at) do
    case String.split(captured_at, "T", parts: 2) do
      [date, _rest] -> date
      _other -> captured_at
    end
  end

  defp capture_date(recording) do
    raise ArgumentError, "recording missing capture date: #{inspect(recording)}"
  end

  defp required_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> to_string(value)
      _other -> raise ArgumentError, "recording missing #{inspect(key)}: #{inspect(map)}"
    end
  end

  defp recording_for(manifest, venue, method) do
    method = to_string(method)

    manifest
    |> Map.get("recordings", [])
    |> Enum.find(fn recording ->
      recording["venue"] == venue and to_string(recording["method"]) == method
    end)
  end
end
