defmodule Bourse.Test.Generator.RestReadContract do
  @moduledoc """
  Generates only the repetitive ExUnit registration for REST-read contracts.

  Provider semantics, arguments, expected values, and branch judgments remain
  data in `priv/authority/rest-read-contracts.json`; runtime assertions live in
  `Bourse.Test.RestReadContractScenario`.
  """

  alias Bourse.Test.RestReadContracts

  defmacro __using__(opts) do
    venue = opts |> Keyword.fetch!(:venue) |> to_string()
    cases = RestReadContracts.cases_for(venue)

    tests = Enum.map(cases, &test_ast/1)

    quote do
      alias Bourse.Test.RestReadContractScenario

      @moduletag :network
      @moduletag :rest_read_contract
      @moduletag unquote(String.to_atom("exchange_#{venue}"))

      setup_all do
        {:ok, context: RestReadContractScenario.setup_venue!(unquote(venue))}
      end

      unquote_splicing(tests)
    end
  end

  defp test_ast(contract_case) do
    escaped = Macro.escape(contract_case)
    method_tag = String.to_atom("method_#{Macro.underscore(contract_case["method"])}")

    quote do
      @tag unquote(method_tag)
      @tag contract_kind: unquote(contract_case["kind"])
      @tag provider_operation: unquote(contract_case["provider_operation"])
      test unquote(contract_case["id"]), %{context: context} do
        RestReadContractScenario.assert_case!(unquote(escaped), context)
      end
    end
  end
end
