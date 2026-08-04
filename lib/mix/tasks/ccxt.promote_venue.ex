defmodule Mix.Tasks.Ccxt.PromoteVenue do
  @shortdoc "Prepares, checks, or promotes an owned venue-spec candidate"

  @moduledoc """
  Creates a provider-authoring candidate from a pinned CCXT reference, or gates
  a completed candidate before writing an owned document.

      mix ccxt.promote_venue --prepare --reference REF --candidate CANDIDATE --report REPORT
      mix ccxt.promote_venue --check --candidate CANDIDATE --report REPORT [--reference REF]
      mix ccxt.promote_venue --promote OUTPUT --candidate CANDIDATE --report REPORT [--reference REF]

  `--check` / `--promote` re-read the pinned reference (from `--reference` or
  `report.reference.path`), verify its bytes against `report.reference.sha256`,
  and re-derive the method inventory from that pin so neither the candidate nor
  the report can silently drop methods.

  Preparation never writes under the runtime authored-spec directory unless
  that path is explicitly supplied. Promotion writes only `OUTPUT`; adding the
  venue to runtime support remains an independent venue delivery.
  """

  use Mix.Task

  alias Bourse.Spec.Promotion

  @switches [
    prepare: :boolean,
    check: :boolean,
    promote: :string,
    reference: :string,
    candidate: :string,
    report: :string,
    force: :boolean
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    ensure_no_positional!(positional)

    case selected_mode(opts) do
      :prepare -> prepare!(opts)
      :check -> check!(opts)
      {:promote, output} -> promote!(opts, output)
      :invalid -> Mix.raise("select exactly one of --prepare, --check, or --promote OUTPUT")
    end
  end

  defp prepare!(opts) do
    reference = required_path!(opts, :reference)
    candidate_path = required_path!(opts, :candidate)
    report_path = required_path!(opts, :report)
    ensure_writable!([candidate_path, report_path], opts[:force])

    {candidate, report} = Promotion.prepare_file!(reference)
    write_json!(candidate_path, candidate)
    write_json!(report_path, report)

    Mix.shell().info(
      "Prepared candidate #{candidate_path} and gap/evidence report #{report_path}; no runtime support claim was made."
    )

    :ok
  end

  defp check!(opts) do
    candidate = read_json!(required_path!(opts, :candidate))
    report = read_json!(required_path!(opts, :report))

    case Promotion.promote(candidate, report, promote_opts(opts)) do
      {:ok, _owned} ->
        Mix.shell().info("Promotion gate passed; the venue remains a candidate until a separate runtime delivery.")
        :ok

      {:error, gaps} ->
        raise_gaps!(gaps)
    end
  end

  defp promote!(opts, output) do
    candidate = read_json!(required_path!(opts, :candidate))
    report = read_json!(required_path!(opts, :report))
    ensure_writable!([output], opts[:force])

    case Promotion.promote(candidate, report, promote_opts(opts)) do
      {:ok, owned} ->
        ensure_runtime_output_supported!(output, owned)
        write_json!(output, owned)
        Mix.shell().info("Wrote promotion-gated owned spec to #{output}; runtime registration is still separate.")
        :ok

      {:error, gaps} ->
        raise_gaps!(gaps)
    end
  end

  defp promote_opts(opts) do
    maybe_put_reference([root: File.cwd!()], opts[:reference])
  end

  defp maybe_put_reference(keyword, path) when is_binary(path) and path != "" do
    Keyword.put(keyword, :reference, path)
  end

  defp maybe_put_reference(keyword, _path), do: keyword

  defp selected_mode(opts) do
    modes =
      Enum.reject(
        [
          if(opts[:prepare], do: :prepare),
          if(opts[:check], do: :check),
          if(is_binary(opts[:promote]), do: {:promote, opts[:promote]})
        ],
        &is_nil/1
      )

    case modes do
      [mode] -> mode
      _modes -> :invalid
    end
  end

  defp required_path!(opts, key) do
    case opts[key] do
      path when is_binary(path) and path != "" -> path
      _value -> Mix.raise("--#{key |> Atom.to_string() |> String.replace("_", "-")} is required")
    end
  end

  defp ensure_writable!(paths, force?) do
    existing = Enum.filter(paths, &File.exists?/1)

    if existing != [] and force? != true do
      Mix.raise("refusing to overwrite #{Enum.join(existing, ", ")}; pass --force")
    end
  end

  defp read_json!(path), do: Bourse.Spec.decode_file!(path)

  defp write_json!(path, document) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Promotion.encode!(document))
  end

  defp ensure_runtime_output_supported!(output, owned) do
    runtime_dir =
      Bourse.Spec.exchanges()
      |> hd()
      |> Bourse.Spec.owned_spec_path()
      |> Path.dirname()
      |> Path.expand()

    if Path.dirname(Path.expand(output)) == runtime_dir do
      venue = get_in(owned, ["exchange", "id"])

      if !Bourse.Spec.supported?(venue) do
        Mix.raise(
          "runtime authored output is governed by #{Bourse.Spec.manifest_path()}; " <>
            "#{inspect(venue)} is not supported"
        )
      end
    end
  end

  @spec raise_gaps!([Promotion.gap()]) :: no_return()
  defp raise_gaps!(gaps) do
    lines = Enum.map_join(gaps, "\n", &"- #{&1.code}: #{&1.message}")
    Mix.raise("promotion refused:\n#{lines}")
  end

  defp ensure_no_positional!([]), do: :ok
  defp ensure_no_positional!(args), do: Mix.raise("unexpected arguments: #{Enum.join(args, " ")}")
end
