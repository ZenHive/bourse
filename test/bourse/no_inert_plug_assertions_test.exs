defmodule Bourse.NoInertPlugAssertionsTest do
  @moduledoc """
  Guards the whole test suite against reintroducing inert in-plug assertions.

  `Bourse.HTTP` wraps the transport in a rescue, so an `ExUnit.AssertionError`
  raised inside a `Req.Test` plug callback never reaches ExUnit as an assertion.
  It is caught and converted into `{:error, %Bourse.Error{type: :network_error}}`,
  whose `message` is the stringified exception. The outer assertion still fails
  — there is no false green — but the failure presents as a `match (=) failed`
  against a `%Bourse.Error{}` struct dump instead of a named request-shape diff.

  Capture the request with `Bourse.Test.RequestCollector` and assert on it after
  the call under test returns, so the assertion runs in the test process.
  """

  use ExUnit.Case, async: true

  @assertion_fns ~w(assert refute flunk assert_raise assert_receive refute_receive assert_in_delta)a

  @scanned Path.wildcard("test/**/*.exs") ++ Path.wildcard("test/**/*.ex")

  defp assertions_in(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {fun, meta, args} = node, acc when is_atom(fun) and is_list(args) ->
          if fun in @assertion_fns, do: {node, [{fun, meta[:line]} | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp offenders(file) do
    {_, found} =
      file
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., _, [{:__aliases__, _, [:Req, :Test]}, kind]}, _meta, args} = node, acc
        when kind in [:stub, :expect] ->
          inner =
            Enum.flat_map(args, fn
              {:fn, _, _} = callback -> assertions_in(callback)
              [{:->, _, _} | _] = clauses -> assertions_in(clauses)
              _ -> []
            end)

          {node, inner ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.map(found, fn {fun, line} -> "#{file}:#{line} #{fun}" end)
  end

  test "no ExUnit assertion is lexically inside a Req.Test plug callback" do
    offenders = Enum.flat_map(@scanned, &offenders/1)

    assert offenders == [],
           """
           Found #{length(offenders)} ExUnit assertion(s) inside a Req.Test plug callback.

           These are inert as diagnostics — Bourse.HTTP's transport rescue converts them into
           {:error, %Bourse.Error{type: :network_error}}, so the failure names the error struct
           rather than the wrong path/param/header.

           Capture with Bourse.Test.RequestCollector and assert after the call returns instead.

           #{Enum.map_join(Enum.sort(offenders), "\n", &("  " <> &1))}
           """
  end
end
