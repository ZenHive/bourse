defmodule Mix.Tasks.Ccxt.CaptureProviderOperations do
  @shortdoc "Captures explicitly reviewed raw provider REST operations"

  @moduledoc """
  Captures a reviewed provider-operation proof set directly over HTTP.

  The inventory must be an exact-revision `mix ccxt.contract_compare` report.
  The plan is a separate human-reviewed safety and reachability decision;
  provider examples are request seeds only and are never auto-executed.

      mix ccxt.capture_provider_operations \
        --inventory /tmp/bourse-contracts/deribit.json \
        --plan priv/authority/deribit/provider-operation-plan.json \
        --output test/fixtures/provider_operations
  """

  use Mix.Task

  alias Bourse.RecordedResponseFixtures

  @switches [inventory: :string, output: :string, plan: :string]

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
    inventory = required_option!(opts, :inventory)
    plan = required_option!(opts, :plan)
    output = required_option!(opts, :output)

    manifest = RecordedResponseFixtures.capture_provider_operations!(inventory, plan, output, runtime_opts)

    Mix.shell().info("captured #{length(manifest["recordings"])} provider-operation proof(s) into #{output}")

    :ok
  end

  defp required_option!(opts, key), do: Keyword.get(opts, key) || Mix.raise("--#{key} is required")
  defp ensure_no_positional!([]), do: :ok
  defp ensure_no_positional!(args), do: Mix.raise("unexpected arguments: #{Enum.join(args, " ")}")
end
