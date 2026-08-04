defmodule Bourse.OptionProposal.MarginImpact do
  @moduledoc """
  Venue-local margin evidence and supported candidate-plan comparison.

  Deribit and OKX expose joint-plan simulations and can be ranked within one
  venue/account/collateral domain. Bybit exposes a single-order quote and
  Derive exposes a position-scenario result; those observations stay
  individually labelled and never enter a portfolio-offset calculation.
  """

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.OptionProposal.MarginImpact.Provider

  @joint_plan_simulation :joint_plan_simulation
  @single_order_margin_quote :single_order_margin_quote
  @position_scenario_margin :position_scenario_margin
  @objectives [:minimize, :maximize]
  @tie_breakers [:plan_order, :plan_id]

  @capabilities %{
    "deribit" => %{
      label: @joint_plan_simulation,
      endpoint: :private_get_simulate_portfolio,
      account_modes: [:portfolio_margin],
      official_reference: "https://docs.deribit.com/api-reference/account-management/private-simulate_portfolio"
    },
    "okx" => %{
      label: @joint_plan_simulation,
      endpoint: :private_post_account_position_builder,
      account_modes: [:multi_currency_margin, :portfolio_margin],
      official_reference: "https://www.okx.com/docs-v5/en/#trading-account-rest-api-position-builder"
    },
    "bybit" => %{
      label: @single_order_margin_quote,
      endpoint: :private_post_v5_order_pre_check,
      account_modes: [:cross_margin, :portfolio_margin],
      official_reference: "https://bybit-exchange.github.io/docs/v5/order/pre-check-order"
    },
    "derive" => %{
      label: @position_scenario_margin,
      endpoint: :private_post_get_margin,
      account_modes: [:standard_margin, :portfolio_margin, :portfolio_margin_2],
      official_reference: "https://docs.derive.xyz/reference/post_private-get-margin"
    }
  }

  @type capability_label ::
          :joint_plan_simulation | :single_order_margin_quote | :position_scenario_margin

  @type capability :: %{
          required(:label) => capability_label(),
          required(:endpoint) => atom(),
          required(:account_modes) => [atom()],
          required(:official_reference) => String.t()
        }

  @type candidate_plan :: %{
          required(:id) => term(),
          required(:exchange) => Exchange.t(),
          required(:account) => term(),
          required(:account_mode) => atom(),
          required(:provider_params) => map(),
          optional(:baseline_provider_params) => map(),
          optional(:request_opts) => keyword()
        }

  @type problem :: %{
          required(:candidate_plans) => [candidate_plan()],
          required(:objective) => :minimize | :maximize,
          required(:weights) => %{required(atom()) => number()},
          required(:tie_break_policy) => [atom()]
        }

  @type result :: %{
          required(:observations) => [map()],
          required(:comparisons) => [map()],
          required(:objective) => :minimize | :maximize,
          required(:weights) => %{required(atom()) => number()},
          required(:tie_break_policy) => [atom()],
          required(:collateral_domains) => [map()],
          required(:cross_venue) => map(),
          required(:portfolio_margin_netting) => false
        }

  @doc "Returns the provider-authoritative margin capability classifications."
  @spec capabilities() :: %{String.t() => capability()}
  def capabilities, do: @capabilities

  @doc "Returns one venue's margin capability or an explicit not-supported error."
  @spec capability(String.t() | atom()) :: {:ok, capability()} | {:error, Error.t()}
  def capability(venue) when is_binary(venue) or is_atom(venue) do
    venue = to_string(venue)

    case Map.fetch(@capabilities, venue) do
      {:ok, capability} ->
        {:ok, capability}

      :error ->
        {:error,
         Error.not_supported(
           message: "venue #{venue} has no provider-owned candidate margin capability",
           exchange: venue
         )}
    end
  end

  @doc """
  Evaluates caller-supplied plans and ranks only eligible joint-plan results.

  Ranking is local to one venue, account, account mode, and provider collateral
  scope. The result deliberately has no global cross-venue winner.
  """
  @spec compare(problem()) :: {:ok, result()} | {:error, Error.t()}
  def compare(problem) when is_map(problem) do
    with :ok <- validate_problem(problem),
         {:ok, plans} <- validate_plans(problem.candidate_plans),
         {:ok, observations} <- observe(plans),
         {:ok, comparisons} <- compare_joint_groups(observations, problem) do
      {:ok, build_result(observations, comparisons, problem)}
    end
  end

  def compare(_problem) do
    {:error, Error.invalid_parameters(message: "margin-impact comparison requires a map")}
  end

  defp validate_problem(problem) do
    cond do
      not is_list(Map.get(problem, :candidate_plans)) or problem.candidate_plans == [] ->
        invalid("candidate_plans must be a non-empty list")

      Map.get(problem, :objective) not in @objectives ->
        invalid("objective must be minimize or maximize")

      not valid_weights?(Map.get(problem, :weights)) ->
        invalid("weights must be a non-empty atom-keyed map of finite positive numbers")

      not valid_tie_break_policy?(Map.get(problem, :tie_break_policy)) ->
        invalid("tie_break_policy must contain plan_order and/or plan_id without duplicates")

      true ->
        :ok
    end
  end

  defp validate_plans(plans) do
    with :ok <- reject_duplicate_ids(plans) do
      plans
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, &validate_and_accumulate_plan/2)
      |> then(fn
        {:ok, validated} -> {:ok, Enum.reverse(validated)}
        error -> error
      end)
    end
  end

  defp validate_and_accumulate_plan({plan, index}, {:ok, acc}) do
    case validate_plan(plan, index) do
      {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
      {:error, %Error{}} = error -> {:halt, error}
    end
  end

  defp validate_plan(plan, index) when is_map(plan) do
    required = [:id, :exchange, :account, :account_mode, :provider_params]
    missing = Enum.reject(required, &Map.has_key?(plan, &1))

    cond do
      missing != [] ->
        invalid("candidate plan is missing #{Enum.join(missing, ", ")}")

      not match?(%Exchange{}, plan.exchange) ->
        invalid("candidate plan exchange must be a Bourse.Exchange")

      is_nil(plan.account) ->
        invalid("candidate plan account cannot be nil")

      not is_map(plan.provider_params) ->
        invalid("candidate plan provider_params must be a map")

      not Keyword.keyword?(Map.get(plan, :request_opts, [])) ->
        invalid("candidate plan request_opts must be a keyword list")

      true ->
        validate_plan_capability(plan, index)
    end
  end

  defp validate_plan(_plan, _index), do: invalid("each candidate plan must be a map")

  defp validate_plan_capability(plan, index) do
    with {:ok, capability} <- capability(plan.exchange.id),
         :ok <- validate_account_mode(plan, capability),
         {:ok, collateral_scope} <- collateral_scope(plan) do
      domain = %{
        venue: plan.exchange.id,
        account: plan.account,
        account_mode: plan.account_mode,
        collateral_scope: collateral_scope,
        portfolio_margin_netting: false
      }

      {:ok,
       plan
       |> Map.put(:capability, capability)
       |> Map.put(:collateral_domain, domain)
       |> Map.put(:plan_index, index)}
    end
  end

  defp validate_account_mode(plan, capability) do
    if plan.account_mode in capability.account_modes do
      :ok
    else
      {:error,
       Error.not_supported(
         message:
           "#{plan.exchange.id} does not expose #{capability.label} for account mode " <>
             inspect(plan.account_mode),
         exchange: plan.exchange.id
       )}
    end
  end

  defp collateral_scope(%{exchange: %Exchange{id: "deribit"}, provider_params: params}) do
    case fetch_param(params, "currency") do
      currency when is_binary(currency) and currency != "" -> {:ok, {:currency, currency}}
      _missing -> invalid("deribit margin plans require provider_params currency")
    end
  end

  defp collateral_scope(%{exchange: %Exchange{id: "derive"}, provider_params: params}) do
    case fetch_param(params, "subaccount_id") do
      subaccount_id when is_integer(subaccount_id) -> {:ok, {:subaccount, subaccount_id}}
      _missing -> invalid("derive margin plans require provider_params subaccount_id")
    end
  end

  defp collateral_scope(%{exchange: %Exchange{id: venue}}) when venue in ["okx", "bybit"], do: {:ok, :whole_account}

  defp observe(plans) do
    plans
    |> Enum.reduce_while({:ok, []}, fn plan, {:ok, observations} ->
      case Provider.fetch(plan) do
        {:ok, observation} ->
          observation =
            Map.merge(observation, %{
              plan_id: plan.id,
              plan_index: plan.plan_index,
              capability: plan.capability,
              capability_label: plan.capability.label,
              comparable?: plan.capability.label == @joint_plan_simulation,
              collateral_domain: plan.collateral_domain
            })

          {:cont, {:ok, [observation | observations]}}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
    |> then(fn
      {:ok, observations} -> {:ok, Enum.reverse(observations)}
      error -> error
    end)
  end

  defp compare_joint_groups(observations, problem) do
    observations
    |> Enum.filter(& &1.comparable?)
    |> Enum.group_by(&domain_key(&1.collateral_domain))
    |> Enum.sort_by(fn {_domain, group} -> group |> Enum.map(& &1.plan_index) |> Enum.min() end)
    |> Enum.reduce_while({:ok, []}, fn {_domain, group}, {:ok, comparisons} ->
      case compare_group(group, problem) do
        {:ok, comparison} -> {:cont, {:ok, [comparison | comparisons]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, comparisons} -> {:ok, Enum.reverse(comparisons)}
      error -> error
    end)
  end

  defp compare_group([observation], problem) do
    {:ok,
     %{
       status: :insufficient_candidates,
       collateral_domain: observation.collateral_domain,
       objective: problem.objective,
       weights: problem.weights,
       tie_break_policy: problem.tie_break_policy,
       ranking: [],
       winner_plan_id: nil
     }}
  end

  defp compare_group(observations, problem) do
    with :ok <- require_metrics(observations, Map.keys(problem.weights)) do
      ranked =
        observations
        |> Enum.map(&score(&1, problem.weights))
        |> Enum.sort_by(&sort_key(&1, problem.objective, problem.tie_break_policy))

      {:ok,
       %{
         status: :ranked,
         collateral_domain: hd(observations).collateral_domain,
         objective: problem.objective,
         weights: problem.weights,
         tie_break_policy: problem.tie_break_policy,
         ranking: Enum.map(ranked, &Map.take(&1, [:plan_id, :score, :metrics])),
         winner_plan_id: hd(ranked).plan_id
       }}
    end
  end

  defp require_metrics(observations, metric_names) do
    missing =
      for observation <- observations,
          metric <- metric_names,
          not is_number(Map.get(observation.metrics, metric)),
          uniq: true,
          do: metric

    if missing == [] do
      :ok
    else
      {:error, Error.not_supported(message: "provider did not expose weighted margin metrics: #{inspect(missing)}")}
    end
  end

  defp score(observation, weights) do
    score =
      Enum.reduce(weights, 0.0, fn {metric, weight}, acc ->
        acc + Map.fetch!(observation.metrics, metric) * weight
      end)

    Map.put(observation, :score, score)
  end

  defp sort_key(observation, objective, policy) do
    score = if objective == :minimize, do: observation.score, else: -observation.score
    {score, Enum.map(policy, &tie_break_value(observation, &1))}
  end

  defp tie_break_value(observation, :plan_order), do: observation.plan_index
  defp tie_break_value(observation, :plan_id), do: inspect(observation.plan_id)

  defp build_result(observations, comparisons, problem) do
    domains =
      observations
      |> Enum.map(& &1.collateral_domain)
      |> Enum.uniq_by(&domain_key/1)

    %{
      observations: observations,
      comparisons: comparisons,
      objective: problem.objective,
      weights: problem.weights,
      tie_break_policy: problem.tie_break_policy,
      collateral_domains: domains,
      cross_venue: %{
        venues: observations |> Enum.map(& &1.collateral_domain.venue) |> Enum.uniq(),
        collateral_domains: domains,
        global_ranking: nil,
        portfolio_margin_netting: false
      },
      portfolio_margin_netting: false
    }
  end

  defp reject_duplicate_ids(plans) do
    ids = Enum.map(plans, &if(is_map(&1), do: Map.get(&1, :id)))

    cond do
      Enum.any?(ids, &is_nil/1) -> invalid("candidate plan ids cannot be nil")
      length(ids) != length(Enum.uniq(ids)) -> invalid("candidate plan ids must be unique")
      true -> :ok
    end
  end

  defp valid_weights?(weights) when is_map(weights) and map_size(weights) > 0 do
    Enum.all?(weights, fn {key, value} ->
      is_atom(key) and is_number(value) and value > 0
    end)
  end

  defp valid_weights?(_weights), do: false

  defp valid_tie_break_policy?(policy) when is_list(policy) and policy != [] do
    Enum.all?(policy, &(&1 in @tie_breakers)) and length(policy) == length(Enum.uniq(policy))
  end

  defp valid_tie_break_policy?(_policy), do: false

  defp domain_key(domain) do
    {domain.venue, domain.account, domain.account_mode, domain.collateral_scope}
  end

  defp fetch_param(params, "currency"), do: Map.get(params, "currency", Map.get(params, :currency))

  defp fetch_param(params, "subaccount_id"), do: Map.get(params, "subaccount_id", Map.get(params, :subaccount_id))

  defp invalid(message), do: {:error, Error.invalid_parameters(message: message)}
end
