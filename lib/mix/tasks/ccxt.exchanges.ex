defmodule Mix.Tasks.Ccxt.Exchanges do
  @shortdoc "List compiled exchanges with module and pattern metadata"

  @moduledoc """
  Lists every exchange in the current spec manifest.

  Shows the generated module, compile/load status, REST signing pattern,
  and WS support for each exchange.

  ## Usage

      mix ccxt.exchanges
      mix ccxt.exchanges --json

  """

  use Mix.Task

  alias Mix.Tasks.Ccxt.Helpers

  @impl true
  def run(args) do
    Mix.Task.run("compile", [])
    {opts, _} = OptionParser.parse!(args, strict: [json: :boolean])
    manifest = Bourse.Spec.load_manifest!()
    rows = Helpers.exchange_rows()
    print_report(opts, manifest, rows)
  end

  @doc "Prints the exchange table or JSON payload from precomputed catalog rows."
  @spec print_report(keyword(), map(), [Helpers.exchange_row()]) :: :ok
  def print_report(opts, manifest, rows) do
    if opts[:json] do
      print_json(manifest, rows)
    else
      print_table(manifest, rows)
    end
  end

  defp print_table(manifest, rows) do
    IO.puts("\n=== Bourse Exchanges ===\n")
    IO.puts("  Schema #{manifest["schema_version"]}")
    IO.puts("  Count: #{manifest["venue_count"]}\n")

    header =
      String.pad_trailing("ID", 14) <>
        String.pad_trailing("MODULE", 22) <>
        String.pad_trailing("LOADED", 8) <>
        String.pad_trailing("WS", 5) <>
        "SIGNING"

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    Enum.each(rows, fn row ->
      IO.puts(format_row(row))
    end)

    IO.puts("")
  end

  defp format_row(row) do
    String.pad_trailing(row.id, 14) <>
      String.pad_trailing(module_name(row.module), 22) <>
      String.pad_trailing(bool_label(row.loaded), 8) <>
      String.pad_trailing(bool_label(row.ws), 5) <>
      inspect(row.signing_pattern)
  end

  defp module_name(nil), do: "-"
  defp module_name(module), do: module |> Module.split() |> List.last()

  defp bool_label(true), do: "yes"
  defp bool_label(false), do: "no"

  defp print_json(manifest, rows) do
    payload = %{
      schema_version: manifest["schema_version"],
      exchange_count: manifest["venue_count"],
      exchanges:
        Enum.map(rows, fn row ->
          %{
            id: row.id,
            module: row.module && Atom.to_string(row.module),
            loaded: row.loaded,
            ws: row.ws,
            signing_pattern: row.signing_pattern,
            ws_subscription_pattern: row.ws_subscription,
            ws_auth_pattern: row.ws_auth
          }
        end)
    }

    IO.puts(Jason.encode!(payload, pretty: true))
  end
end
