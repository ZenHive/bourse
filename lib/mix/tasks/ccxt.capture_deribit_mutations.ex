defmodule Mix.Tasks.Ccxt.CaptureDeribitMutations do
  @shortdoc "Runs the reviewed Deribit reversible-mutation lifecycles against testnet"

  @moduledoc """
  Executes the reviewed reversible mutation lifecycles and registers what they observed.

      mix ccxt.capture_deribit_mutations

  Every step is authorized against `priv/authority/deribit/mutation-adjudication.json`
  before a request is built, so an unadjudicated, refused, unsafe or unreachable
  operation is refused before anything leaves the machine. The task is an explicit
  network operation against `test.deribit.com` and is never part of the offline
  test suite; the committed corpus it writes is what the suite and
  `mix ccxt.oracle_gate` validate.

      mix ccxt.capture_deribit_mutations --output test/fixtures/provider_operations/deribit_mutations
  """

  use Mix.Task

  alias Bourse.OracleProvenance.MutationAdjudication
  alias Bourse.OracleProvenance.MutationAdjudication.Lifecycle

  @switches [output: :string, plan: :string, register: :string]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args), do: run(args, [])

  @doc false
  @spec run([String.t()], keyword()) :: :ok
  def run(args, runtime_opts) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:bourse)

    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    ensure_no_positional!(positional)
    defaults = MutationAdjudication.defaults()
    output = Keyword.get(opts, :output, defaults[:root])

    capture_opts =
      runtime_opts
      |> Keyword.put_new(:register_path, Keyword.get(opts, :register, defaults[:register_path]))
      |> Keyword.put_new(:plan_path, Keyword.get(opts, :plan, defaults[:plan_path]))

    manifest = Lifecycle.capture!(output, capture_opts)

    Enum.each(manifest["lifecycles"], fn lifecycle ->
      Mix.shell().info(
        "#{lifecycle["lifecycle_id"]}: #{lifecycle["operation_id"]} reversed by " <>
          "#{lifecycle["reversal_operation_id"]}, cleanup #{lifecycle["cleanup_outcome"]}, " <>
          "final state #{lifecycle["final_state"]}"
      )
    end)

    verified = Enum.count(manifest["operations"], &(&1["evidence"] == "verified"))

    Mix.shell().info(
      "captured #{length(manifest["recordings"])} lifecycle step(s) into #{output}; " <>
        "#{verified} of #{length(manifest["operations"])} adjudicated operations carry reality evidence"
    )

    :ok
  end

  defp ensure_no_positional!([]), do: :ok
  defp ensure_no_positional!(args), do: Mix.raise("unexpected arguments: #{Enum.join(args, " ")}")
end
