defmodule Bourse.OptionProposal.MarginImpact.Provider do
  @moduledoc """
  Venue-owned margin simulation adapters.

  Each adapter calls the venue's native endpoint and exposes only values the
  provider returned. The small amount of arithmetic is limited to differences
  between provider-reported before/after or baseline/scenario values.
  """

  alias Bourse.Error
  alias Bourse.Exchange

  @type plan :: %{
          required(:exchange) => Exchange.t(),
          required(:provider_params) => map(),
          optional(:baseline_provider_params) => map(),
          optional(:request_opts) => keyword()
        }

  @type observation :: %{
          required(:metrics) => %{optional(atom()) => number()},
          required(:effects) => %{
            required(:margin) => map(),
            required(:capacity) => map(),
            required(:liquidation) => map()
          },
          required(:provider_response) => map()
        }

  @doc "Calls the venue-native margin endpoint for one caller-supplied plan."
  @spec fetch(plan()) :: {:ok, observation()} | {:error, Error.t()}
  def fetch(%{exchange: %Exchange{id: "deribit"}} = plan), do: fetch_deribit(plan)
  def fetch(%{exchange: %Exchange{id: "okx"}} = plan), do: fetch_okx(plan)
  def fetch(%{exchange: %Exchange{id: "bybit"}} = plan), do: fetch_bybit(plan)
  def fetch(%{exchange: %Exchange{id: "derive"}} = plan), do: fetch_derive(plan)

  defp fetch_deribit(plan) do
    with {:ok, %{body: body}} <-
           Bourse.Deribit.private_get_simulate_portfolio(
             plan.exchange,
             plan.provider_params,
             request_opts(plan)
           ),
         {:ok, result} <- result_object(body, "deribit") do
      metrics =
        result
        |> numeric_fields(%{
          initial_margin: "initial_margin",
          maintenance_margin: "maintenance_margin",
          projected_initial_margin: "projected_initial_margin",
          projected_maintenance_margin: "projected_maintenance_margin",
          available_funds: "available_funds"
        })
        |> put_impact(:initial_margin_impact, :projected_initial_margin, :initial_margin)
        |> put_impact(
          :maintenance_margin_impact,
          :projected_maintenance_margin,
          :maintenance_margin
        )

      {:ok, observation(metrics, body, [:available_funds])}
    end
  end

  defp fetch_okx(%{baseline_provider_params: baseline_params} = plan) when is_map(baseline_params) do
    with {:ok, %{body: baseline_body}} <-
           Bourse.Okx.private_post_account_position_builder(
             plan.exchange,
             baseline_params,
             request_opts(plan)
           ),
         {:ok, baseline} <- okx_result(baseline_body),
         {:ok, %{body: scenario_body}} <-
           Bourse.Okx.private_post_account_position_builder(
             plan.exchange,
             plan.provider_params,
             request_opts(plan)
           ),
         {:ok, scenario} <- okx_result(scenario_body) do
      baseline_metrics = okx_metrics(baseline)

      metrics =
        scenario
        |> okx_metrics()
        |> put_impact(:initial_margin_impact, :initial_margin, baseline_metrics)
        |> put_impact(:maintenance_margin_impact, :maintenance_margin, baseline_metrics)
        |> put_impact(:equity_change, :equity, baseline_metrics)
        |> put_impact(:margin_ratio_change, :margin_ratio, baseline_metrics)

      response = %{baseline: baseline_body, scenario: scenario_body}
      {:ok, observation(metrics, response, [:equity, :margin_ratio])}
    end
  end

  defp fetch_okx(_plan) do
    {:error, Error.invalid_parameters(message: "okx joint-plan simulation requires baseline_provider_params")}
  end

  defp fetch_bybit(plan) do
    with {:ok, %{body: body}} <-
           Bourse.Bybit.private_post_v5_order_pre_check(
             plan.exchange,
             plan.provider_params,
             request_opts(plan)
           ),
         {:ok, result} <- bybit_result(body) do
      metrics =
        result
        |> numeric_fields(%{
          pre_initial_margin_rate_e4: "preImrE4",
          pre_maintenance_margin_rate_e4: "preMmrE4",
          post_initial_margin_rate_e4: "postImrE4",
          post_maintenance_margin_rate_e4: "postMmrE4"
        })
        |> put_impact(
          :initial_margin_rate_impact_e4,
          :post_initial_margin_rate_e4,
          :pre_initial_margin_rate_e4
        )
        |> put_impact(
          :maintenance_margin_rate_impact_e4,
          :post_maintenance_margin_rate_e4,
          :pre_maintenance_margin_rate_e4
        )

      {:ok, observation(metrics, body, [])}
    end
  end

  defp fetch_derive(plan) do
    with {:ok, %{body: body}} <-
           Bourse.Derive.private_post_get_margin(
             plan.exchange,
             plan.provider_params,
             request_opts(plan)
           ),
         {:ok, result} <- result_object(body, "derive") do
      metrics =
        result
        |> numeric_fields(%{
          initial_margin: "post_initial_margin",
          maintenance_margin: "post_maintenance_margin",
          pre_initial_margin: "pre_initial_margin",
          pre_maintenance_margin: "pre_maintenance_margin"
        })
        |> put_impact(:initial_margin_impact, :initial_margin, :pre_initial_margin)
        |> put_impact(:maintenance_margin_impact, :maintenance_margin, :pre_maintenance_margin)

      capacity = %{is_valid_trade: Map.get(result, "is_valid_trade")}
      {:ok, observation(metrics, body, [], capacity)}
    end
  end

  defp okx_metrics(result) do
    numeric_fields(result, %{
      initial_margin: "totalImr",
      maintenance_margin: "totalMmr",
      equity: "eq",
      margin_ratio: "marginRatio"
    })
  end

  defp observation(metrics, response, capacity_keys, extra_capacity \\ %{}) do
    capacity = metrics |> Map.take(capacity_keys) |> Map.merge(extra_capacity)

    %{
      metrics: metrics,
      effects: %{
        margin:
          Map.drop(metrics, [
            :available_funds,
            :equity,
            :equity_change,
            :margin_ratio,
            :margin_ratio_change
          ]),
        capacity: capacity,
        liquidation: %{}
      },
      provider_response: response
    }
  end

  defp okx_result(%{"code" => "0", "data" => [result | _]}) when is_map(result), do: {:ok, result}

  defp okx_result(body), do: invalid_response("okx", body)

  defp bybit_result(%{"retCode" => 0, "result" => result}) when is_map(result), do: {:ok, result}

  defp bybit_result(body), do: invalid_response("bybit", body)

  defp result_object(%{"result" => result}, _venue) when is_map(result), do: {:ok, result}
  defp result_object(body, venue), do: invalid_response(venue, body)

  defp invalid_response(venue, body) do
    {:error,
     Error.exchange_error(
       "Unexpected #{venue} margin response",
       exchange: venue,
       raw: body
     )}
  end

  defp numeric_fields(source, fields) do
    Enum.reduce(fields, %{}, fn {name, provider_name}, acc ->
      case number(Map.get(source, provider_name)) do
        nil -> acc
        value -> Map.put(acc, name, value)
      end
    end)
  end

  defp number(value) when is_number(value), do: value * 1.0

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp number(_value), do: nil

  defp put_impact(metrics, impact, after_key, before_key) when is_atom(before_key) do
    with after_value when is_number(after_value) <- Map.get(metrics, after_key),
         before_value when is_number(before_value) <- Map.get(metrics, before_key) do
      Map.put(metrics, impact, after_value - before_value)
    else
      _missing -> metrics
    end
  end

  defp put_impact(metrics, impact, after_key, baseline) when is_map(baseline) do
    with after_value when is_number(after_value) <- Map.get(metrics, after_key),
         before_value when is_number(before_value) <- Map.get(baseline, after_key) do
      Map.put(metrics, impact, after_value - before_value)
    else
      _missing -> metrics
    end
  end

  defp request_opts(plan), do: Map.get(plan, :request_opts, [])
end
