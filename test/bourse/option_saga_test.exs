defmodule Bourse.OptionSagaTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.OptionProposal.Result
  alias Bourse.OptionSaga
  alias Bourse.OptionSaga.Executor
  alias Bourse.OptionSaga.Journal
  alias Bourse.Order

  @now 1_800_000_000_000
  @max_age_ms 10_000

  describe "new/2 and step/3 approval gate" do
    test "builds stable provider-safe plan, option-leg, and hedge identifiers" do
      approval = approval(hedge: hedge())

      assert {:ok, %Journal{} = first} = new_journal(approval)
      assert {:ok, %Journal{} = second} = new_journal(approval)

      assert first.plan_id == second.plan_id
      assert Enum.map(first.legs, & &1.execution_id) == Enum.map(second.legs, & &1.execution_id)
      assert Enum.map(first.legs, & &1.client_order_id) == Enum.map(second.legs, & &1.client_order_id)
      assert Enum.map(first.legs, & &1.role) == [:option, :hedge]
      assert Enum.all?(first.legs, &(String.length(&1.client_order_id) <= 36))
      assert Enum.all?(first.legs, &Regex.match?(~r/^[A-Za-z0-9_-]+$/, &1.client_order_id))

      assert Enum.all?(first.legs, fn leg ->
               Enum.map(leg.transitions, & &1.state) == [:planned]
             end)
    end

    test "rejects rejected, stale, future-dated, duplicate, and changed approvals before submission" do
      rejected = approval(status: :rejected)

      assert {:error, %Error{type: :invalid_parameters, message: rejected_message}} =
               new_journal(rejected)

      assert rejected_message =~ "requires an approved"

      stale = approval(observed_at: @now - @max_age_ms - 1)
      future = approval(observed_at: @now + 1)

      assert {:error, %Error{message: stale_message}} = new_journal(stale)
      assert stale_message =~ "stale or future-dated"
      assert {:error, %Error{message: future_message}} = new_journal(future)
      assert future_message =~ "stale or future-dated"

      duplicate_leg = leg(id: "same")
      duplicate = approval(legs: [duplicate_leg, duplicate_leg])

      assert {:error, %Error{message: duplicate_message}} = new_journal(duplicate)
      assert duplicate_message =~ "unique executable legs"

      original = approval()
      assert {:ok, journal} = new_journal(original)
      changed = put_in(original.plan.legs, [leg(id: "changed")])

      assert {:error, %Error{message: changed_message}} =
               OptionSaga.step(journal, changed, now_ms: @now)

      assert changed_message =~ "approval changed"

      assert {:error, %Error{message: expired_message}} =
               OptionSaga.step(journal, original, now_ms: @now + @max_age_ms + 1)

      assert expired_message =~ "stale"
      assert Enum.map(hd(journal.legs).transitions, & &1.state) == [:planned]
    end
  end

  describe "pure step/resume journal" do
    test "preserves submitted, accepted, open, partial, and filled transitions" do
      approval = approval()
      assert {:ok, journal} = new_journal(approval)

      assert {:ok, %{action: :submit} = submit, submitted} =
               OptionSaga.step(journal, approval, now_ms: @now + 1)

      assert leg_states(submitted, submit) == [:planned, :submitted]

      ack = %Order{id: "venue-1", client_order_id: submit.client_order_id}
      assert {:ok, accepted} = OptionSaga.resume(submitted, submit, {:ok, ack}, now_ms: @now + 2)
      assert leg_states(accepted, submit) == [:planned, :submitted, :accepted]

      assert {:ok, %{action: :reconcile} = reconcile_open, monitoring} =
               OptionSaga.step(accepted, approval, now_ms: @now + 3)

      open = %Order{id: "venue-1", status: "open", amount: 1.0, filled: 0.0, remaining: 1.0}

      assert {:ok, open_journal} =
               OptionSaga.resume(monitoring, reconcile_open, {:ok, open}, now_ms: @now + 4)

      assert List.last(leg_states(open_journal, submit)) == :open

      assert {:ok, %{action: :reconcile} = reconcile_partial, monitoring} =
               OptionSaga.step(open_journal, approval, now_ms: @now + 5)

      partial = %Order{id: "venue-1", status: "open", amount: 1.0, filled: 0.4, remaining: 0.6}

      assert {:ok, partial_journal} =
               OptionSaga.resume(monitoring, reconcile_partial, {:ok, partial}, now_ms: @now + 6)

      assert List.last(leg_states(partial_journal, submit)) == :partial

      assert {:ok, %{action: :reconcile} = reconcile_filled, monitoring} =
               OptionSaga.step(partial_journal, approval, now_ms: @now + 7)

      filled = %Order{id: "venue-1", status: "closed", amount: 1.0, filled: 1.0, remaining: 0.0}

      assert {:ok, filled_journal} =
               OptionSaga.resume(monitoring, reconcile_filled, {:ok, filled}, now_ms: @now + 8)

      assert {:done, %Journal{status: :completed} = completed} =
               OptionSaga.step(filled_journal, approval, now_ms: @now + 9)

      assert Enum.uniq(leg_states(completed, submit)) == [:planned, :submitted, :accepted, :open, :partial, :filled]
      assert completed.residual_risk == []
    end

    test "transient and unknown submission statuses remain live and reconcile without resubmission" do
      approval = approval()

      for order <- [
            %Order{
              id: "speed-bumped",
              status: "open",
              amount: 1.0,
              filled: 0.0,
              remaining: 1.0,
              info: %{"order_state" => "speed_bumped", "trades" => []}
            },
            %Order{
              id: "provider-added",
              status: "provider_added",
              amount: 1.0,
              filled: 0.0,
              remaining: 1.0
            }
          ] do
        assert {:ok, journal} = new_journal(approval)

        assert {:ok, %{action: :submit} = submit, submitted} =
                 OptionSaga.step(journal, approval, now_ms: @now + 1)

        assert {:ok, pending} =
                 OptionSaga.resume(submitted, submit, {:ok, order}, now_ms: @now + 2)

        refute pending.failure
        refute List.last(leg_states(pending, submit)) in [:filled, :failed]

        assert {:ok, %{action: :reconcile, order_id: order_id}, _monitoring} =
                 OptionSaga.step(pending, approval, now_ms: @now + 3)

        assert order_id == order.id
      end
    end

    test "approval expiry after an acknowledgement blocks the next leg and starts compensation" do
      approval = approval(legs: [leg(id: "first"), leg(id: "second")])
      assert {:ok, journal} = new_journal(approval)
      assert {:ok, first_submit, submitted} = OptionSaga.step(journal, approval, now_ms: @now + 1)

      acknowledged = %Order{id: "provider-1", client_order_id: first_submit.client_order_id}

      assert {:ok, running} =
               OptionSaga.resume(submitted, first_submit, {:ok, acknowledged}, now_ms: @now + 2)

      assert {:ok, %{action: :cancel, execution_id: first_execution}, compensating} =
               OptionSaga.step(running, approval, now_ms: @now + @max_age_ms + 1)

      assert first_execution == first_submit.execution_id
      assert compensating.status == :compensating
      assert %Error{type: :invalid_parameters} = compensating.failure.reason
      assert Enum.at(compensating.legs, 1).state == :failed
    end

    test "ambiguous submission remains unknown until absence is reconciled and never duplicates an acknowledgement" do
      approval = approval()
      assert {:ok, journal} = new_journal(approval)
      assert {:ok, submit, submitted} = OptionSaga.step(journal, approval, now_ms: @now + 1)

      timeout = Error.network_error(message: "timeout")
      assert {:ok, unknown} = OptionSaga.resume(submitted, submit, {:error, timeout}, now_ms: @now + 2)
      assert List.last(leg_states(unknown, submit)) == :unknown

      assert {:ok, %{action: :reconcile, client_order_id: client_id} = reconcile, reconciling} =
               OptionSaga.step(unknown, approval, now_ms: @now + 3)

      assert client_id == submit.client_order_id

      assert {:ok, replanned} =
               OptionSaga.resume(reconciling, reconcile, {:not_found, %{sources: [:provider]}}, now_ms: @now + 4)

      assert List.last(leg_states(replanned, submit)) == :planned

      assert {:ok, %{action: :submit, client_order_id: ^client_id} = retry, retried} =
               OptionSaga.step(replanned, approval, now_ms: @now + 5)

      ack = %Order{id: "accepted", client_order_id: client_id}
      assert {:ok, accepted} = OptionSaga.resume(retried, retry, {:ok, ack}, now_ms: @now + 6)

      assert {:ok, %{action: :reconcile}, _} =
               OptionSaga.step(accepted, approval, now_ms: @now + 7)

      assert {:ok, ^accepted} = OptionSaga.resume(accepted, retry, {:ok, ack}, now_ms: @now + 8)
    end

    test "failure stops later legs, reconciles ambiguous cancellation, and reports partial-fill residual risk" do
      approval = approval(legs: [leg(id: "first"), leg(id: "fails"), leg(id: "never")])
      assert {:ok, journal} = new_journal(approval)

      assert {:ok, first_submit, journal} = OptionSaga.step(journal, approval, now_ms: @now + 1)

      first_open = %Order{
        id: "open-1",
        client_order_id: first_submit.client_order_id,
        status: "open",
        amount: 1.0,
        filled: 0.0,
        remaining: 1.0
      }

      assert {:ok, journal} =
               OptionSaga.resume(journal, first_submit, {:ok, first_open}, now_ms: @now + 2)

      assert {:ok, second_submit, journal} = OptionSaga.step(journal, approval, now_ms: @now + 3)
      rejection = Error.invalid_order(code: 170_141, message: "Duplicate clientOrderId")

      assert {:ok, %Journal{status: :compensating} = journal} =
               OptionSaga.resume(journal, second_submit, {:error, rejection}, now_ms: @now + 4)

      never_leg = Enum.find(journal.legs, &(&1.id == "never"))
      assert Enum.map(never_leg.transitions, & &1.state) == [:planned]
      assert Enum.find(journal.legs, &(&1.id == "fails")).state == :failed

      assert {:ok, %{action: :cancel} = first_cancel, journal} =
               OptionSaga.step(journal, approval, now_ms: @now + 5)

      cancel_ack = %Order{id: "open-1", client_order_id: first_submit.client_order_id}

      assert {:ok, journal} =
               OptionSaga.resume(journal, first_cancel, {:ok, cancel_ack}, now_ms: @now + 6)

      assert List.last(leg_states(journal, first_submit)) == :unknown
      assert length(journal.compensations) == 1

      assert {:ok, %{action: :reconcile} = cancel_reconcile, journal} =
               OptionSaga.step(journal, approval, now_ms: @now + 7)

      partial = %Order{id: "open-1", status: "open", amount: 1.0, filled: 0.4, remaining: 0.6}

      assert {:ok, journal} =
               OptionSaga.resume(journal, cancel_reconcile, {:ok, partial}, now_ms: @now + 8)

      assert {:ok, %{action: :cancel} = retry_cancel, journal} =
               OptionSaga.step(journal, approval, now_ms: @now + 9)

      cancelled = %Order{id: "open-1", status: "canceled", amount: 1.0, filled: 0.4, remaining: 0.6}

      assert {:ok, journal} =
               OptionSaga.resume(journal, retry_cancel, {:ok, cancelled}, now_ms: @now + 10)

      assert {:halted, %Journal{status: :halted} = halted} =
               OptionSaga.step(journal, approval, now_ms: @now + 11)

      assert length(halted.compensations) == 2
      assert Enum.map(halted.compensations, & &1.outcome) == [{:ok, cancel_ack}, {:ok, cancelled}]
      assert Enum.find(halted.legs, &(&1.id == "first")).state == :cancelled

      assert [
               %{
                 leg_id: "first",
                 filled: 0.4,
                 state: :cancelled,
                 action_required: :explicit_follow_up_required
               }
             ] = halted.residual_risk
    end

    test "definite cancellation failure is returned and leaves explicit open risk" do
      approval = approval(legs: [leg(id: "open"), leg(id: "fails")])
      assert {:ok, journal} = new_journal(approval)
      assert {:ok, first_submit, journal} = OptionSaga.step(journal, approval, now_ms: @now + 1)

      open = %Order{id: "open-1", status: "open", amount: 1.0, filled: 0.0, remaining: 1.0}
      assert {:ok, journal} = OptionSaga.resume(journal, first_submit, {:ok, open}, now_ms: @now + 2)
      assert {:ok, second_submit, journal} = OptionSaga.step(journal, approval, now_ms: @now + 3)

      assert {:ok, journal} =
               OptionSaga.resume(journal, second_submit, {:error, Error.invalid_order(message: "rejected")},
                 now_ms: @now + 4
               )

      assert {:ok, cancel, journal} = OptionSaga.step(journal, approval, now_ms: @now + 5)
      cancel_error = Error.permission_denied(message: "cancel denied")

      assert {:ok, journal} =
               OptionSaga.resume(journal, cancel, {:error, cancel_error}, now_ms: @now + 6)

      assert {:halted, halted} = OptionSaga.step(journal, approval, now_ms: @now + 7)
      assert [%{outcome: {:error, ^cancel_error}}] = halted.compensations
      assert [%{leg_id: "open", state: :open, action_required: :explicit_follow_up_required}] = halted.residual_risk
    end

    test "records explicit unknown variants, acknowledged absence, terminated acks, and malformed outcomes" do
      approval = approval()
      assert {:ok, journal} = new_journal(approval)
      assert {:ok, submit, journal} = OptionSaga.step(journal, approval, now_ms: @now + 1)

      assert {:ok, unknown} =
               OptionSaga.resume(journal, submit, {:unknown, :socket_closed}, now_ms: @now + 2)

      assert {:ok, reconcile, unknown} = OptionSaga.step(unknown, approval, now_ms: @now + 3)

      assert {:ok, still_unknown} =
               OptionSaga.resume(unknown, reconcile, {:error, Error.network_error(message: "read timeout")},
                 now_ms: @now + 4
               )

      assert {:ok, reconcile, still_unknown} =
               OptionSaga.step(still_unknown, approval, now_ms: @now + 5)

      assert {:ok, still_unknown} =
               OptionSaga.resume(still_unknown, reconcile, {:unknown, :history_lag}, now_ms: @now + 6)

      assert List.last(leg_states(still_unknown, submit)) == :unknown

      assert {:ok, fresh} = new_journal(approval)
      assert {:ok, submit, fresh} = OptionSaga.step(fresh, approval, now_ms: @now + 10)
      ack = %Order{id: "acknowledged"}
      assert {:ok, accepted} = OptionSaga.resume(fresh, submit, {:ok, ack}, now_ms: @now + 11)
      assert {:ok, reconcile, accepted} = OptionSaga.step(accepted, approval, now_ms: @now + 12)

      assert {:ok, absent_unknown} =
               OptionSaga.resume(accepted, reconcile, {:not_found, %{sources: [:history]}}, now_ms: @now + 13)

      assert List.last(leg_states(absent_unknown, submit)) == :unknown

      assert {:ok, fresh} = new_journal(approval)
      assert {:ok, submit, fresh} = OptionSaga.step(fresh, approval, now_ms: @now + 20)

      assert {:ok, terminated} =
               OptionSaga.resume(fresh, submit, {:ok, %Order{id: "cancelled", status: "canceled"}}, now_ms: @now + 21)

      assert terminated.status == :compensating
      assert terminated.failure.reason == {:order_terminated_on_submission, :cancelled}

      assert {:ok, fresh} = new_journal(approval)
      assert {:ok, submit, fresh} = OptionSaga.step(fresh, approval, now_ms: @now + 30)
      assert {:ok, malformed} = OptionSaga.resume(fresh, submit, :bad_outcome, now_ms: @now + 31)
      assert malformed.failure.reason == {:unexpected_submit_outcome, :bad_outcome}
    end

    test "records ambiguous and absent cancellation outcomes without issuing a new leg" do
      for outcome <- [
            {:error, Error.network_error(message: "cancel timeout")},
            {:not_found, %{source: :provider}},
            {:unknown, :lost_ack}
          ] do
        approval = approval(legs: [leg(id: "open"), leg(id: "fails")])
        assert {:ok, journal} = new_journal(approval)
        assert {:ok, first, journal} = OptionSaga.step(journal, approval, now_ms: @now + 1)

        assert {:ok, journal} =
                 OptionSaga.resume(
                   journal,
                   first,
                   {:ok, %Order{id: "open", status: "open", amount: 1.0, filled: 0.0}},
                   now_ms: @now + 2
                 )

        assert {:ok, second, journal} = OptionSaga.step(journal, approval, now_ms: @now + 3)

        assert {:ok, journal} =
                 OptionSaga.resume(journal, second, {:error, Error.invalid_order(message: "fail")}, now_ms: @now + 4)

        assert {:ok, cancel, journal} = OptionSaga.step(journal, approval, now_ms: @now + 5)
        assert {:ok, journal} = OptionSaga.resume(journal, cancel, outcome, now_ms: @now + 6)
        assert [%{outcome: ^outcome}] = journal.compensations
        assert {:ok, %{action: :reconcile}, _journal} = OptionSaga.step(journal, approval, now_ms: @now + 7)
      end
    end

    test "rejects mismatched outcomes and safely halts an exhausted non-terminal journal" do
      approval = approval()
      assert {:ok, journal} = new_journal(approval)
      assert {:ok, command, journal} = OptionSaga.step(journal, approval, now_ms: @now + 1)

      assert {:error, %Error{message: message}} =
               OptionSaga.resume(journal, %{command | plan_id: "another"}, {:unknown, :lost}, now_ms: @now + 2)

      assert message =~ "does not match"

      exhausted = %{journal | status: :monitoring, legs: Enum.map(journal.legs, &%{&1 | state: :failed})}
      assert {:halted, %Journal{status: :halted}} = OptionSaga.step(exhausted, approval, now_ms: @now + 3)

      assert {:done, completed} =
               OptionSaga.step(%{journal | status: :completed}, approval, now_ms: @now + 4)

      assert {:halted, halted} =
               OptionSaga.step(%{journal | status: :halted}, approval, now_ms: @now + 5)

      assert completed.status == :completed
      assert halted.status == :halted
    end
  end

  describe "execute/3" do
    test "maps stable client id to submission, executes cancellation, and selects the venue/account exchange" do
      approval = approval()
      assert {:ok, journal} = new_journal(approval)
      assert {:ok, submit, _journal} = OptionSaga.step(journal, approval, now_ms: @now + 1)
      exchange = Exchange.new!("bybit")
      order = %Order{id: "provider", client_order_id: submit.client_order_id}
      owner = self()

      call = fn method, passed_exchange, args, opts ->
        send(owner, {:call, method, passed_exchange.id, args, opts})
        {:ok, order}
      end

      assert {:ok, ^order} =
               OptionSaga.execute(submit, %{{"bybit", "demo"} => exchange},
                 call: call,
                 request_opts: [base_url: "https://demo.invalid"]
               )

      assert_receive {:call, :create_order, "bybit", ["BTC/USD:BTC-260131-100000-C", "limit", "buy", 1.0], order_opts}

      assert order_opts[:clientOrderId] == submit.client_order_id
      assert order_opts[:price] == 0.01
      assert order_opts[:base_url] == "https://demo.invalid"

      cancel = %{submit | action: :cancel, order_id: "provider"}
      assert {:ok, ^order} = OptionSaga.execute(cancel, %{"bybit" => exchange}, call: call)
      assert_receive {:call, :cancel_order, "bybit", ["provider"], cancel_opts}
      assert cancel_opts[:symbol] == submit.symbol

      market_submit = %{submit | price: nil}
      assert {:ok, ^order} = OptionSaga.execute(market_submit, %{"bybit" => exchange}, call: call)
      assert_receive {:call, :create_order, "bybit", _args, market_opts}
      refute Keyword.has_key?(market_opts, :price)
    end

    test "reconciles by venue order id then client id collections without resubmission" do
      approval = approval()
      assert {:ok, journal} = new_journal(approval)
      assert {:ok, submit, _journal} = OptionSaga.step(journal, approval, now_ms: @now + 1)
      exchange = Exchange.new!("bybit")
      reconcile = %{submit | action: :reconcile, order_id: "missing"}
      found = %Order{id: "provider", client_order_id: submit.client_order_id, status: "open"}
      owner = self()

      call = fn
        :fetch_order, _exchange, ["missing"], opts ->
          send(owner, {:read, :fetch_order, opts})
          {:error, Error.order_not_found(message: "not visible by venue id")}

        :fetch_open_orders, _exchange, [], opts ->
          send(owner, {:read, :fetch_open_orders, opts})
          {:ok, [%Order{id: "other", client_order_id: "other"}]}

        :fetch_closed_orders, _exchange, [], opts ->
          send(owner, {:read, :fetch_closed_orders, opts})
          {:ok, [found]}
      end

      assert {:ok, ^found} =
               OptionSaga.execute(reconcile, %{{"bybit", "demo"} => exchange}, call: call)

      assert_receive {:read, :fetch_order, _}
      assert_receive {:read, :fetch_open_orders, open_opts}
      assert open_opts[:clientOrderId] == submit.client_order_id
      assert_receive {:read, :fetch_closed_orders, _}
      refute_receive {:read, :fetch_canceled_orders, _}
    end

    test "returns a direct venue-id reconciliation and a non-not-found read error" do
      approval = approval()
      assert {:ok, journal} = new_journal(approval)
      assert {:ok, submit, _journal} = OptionSaga.step(journal, approval, now_ms: @now + 1)
      exchange = Exchange.new!("bybit")
      reconcile = %{submit | action: :reconcile, order_id: "known"}
      found = %Order{id: "known", status: "open"}

      assert {:ok, ^found} =
               OptionSaga.execute(reconcile, %{"bybit" => exchange},
                 call: fn :fetch_order, _exchange, ["known"], _opts -> {:ok, found} end
               )

      error = Error.permission_denied(message: "read denied")

      assert {:error, ^error} =
               OptionSaga.execute(reconcile, %{"bybit" => exchange},
                 call: fn :fetch_order, _exchange, ["known"], _opts -> {:error, error} end
               )
    end

    test "returns proven absence, collection errors, and missing-domain errors explicitly" do
      approval = approval()
      assert {:ok, journal} = new_journal(approval)
      assert {:ok, submit, _journal} = OptionSaga.step(journal, approval, now_ms: @now + 1)
      exchange = Exchange.new!("bybit")
      reconcile = %{submit | action: :reconcile, order_id: nil}

      absent_call = fn method, _exchange, [], _opts
                       when method in [
                              :fetch_open_orders,
                              :fetch_closed_orders,
                              :fetch_canceled_orders
                            ] ->
        {:ok, [%{}]}
      end

      assert {:not_found, %{sources: [:fetch_open_orders, :fetch_closed_orders, :fetch_canceled_orders]}} =
               OptionSaga.execute(reconcile, %{"bybit" => exchange}, call: absent_call)

      error = Error.network_error(message: "read timeout")
      error_call = fn :fetch_open_orders, _exchange, [], _opts -> {:error, error} end
      assert {:error, ^error} = OptionSaga.execute(reconcile, %{"bybit" => exchange}, call: error_call)

      assert {:error, %Error{type: :invalid_parameters, message: message}} =
               OptionSaga.execute(reconcile, %{})

      assert message =~ ~s({"bybit", "demo"})
    end

    test "rejects an unexpected collection result and uses the default Bourse call boundary" do
      approval = approval()
      assert {:ok, journal} = new_journal(approval)
      assert {:ok, submit, _journal} = OptionSaga.step(journal, approval, now_ms: @now + 1)
      exchange = Exchange.new!("bybit")
      reconcile = %{submit | action: :reconcile, order_id: nil}

      assert {:error, %Error{type: :exchange_error, message: message}} =
               OptionSaga.execute(reconcile, %{"bybit" => exchange},
                 call: fn :fetch_open_orders, _exchange, [], _opts -> {:ok, :not_a_list} end
               )

      assert message =~ "unexpected fetch_open_orders"

      credentials = Bourse.Credentials.new!(api_key: "key", secret: "secret")
      exchange = Exchange.new!("bybit", credentials: credentials)

      exchange = %{
        exchange
        | markets: [
            %Bourse.Market{
              id: "BTC-31JAN26-100000-C-BTC",
              symbol: submit.symbol,
              base: "BTC",
              quote: "USD",
              settle: "BTC",
              type: "option",
              option: true,
              contract: true,
              active: true,
              quantity_unit: "base",
              native_quantity_unit: "base",
              native_quantity_field: "qty",
              native_amount_step: 0.01,
              precision: %{"amount" => 0.01, "price" => 0.01}
            }
          ]
      }

      stub = {__MODULE__, System.unique_integer([:positive])}

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "retCode" => 0,
          "retMsg" => "OK",
          "result" => %{"orderId" => "provider", "orderLinkId" => submit.client_order_id},
          "retExtInfo" => %{},
          "time" => @now
        })
      end)

      assert {:ok, %Order{id: "provider", client_order_id: client_id}} =
               OptionSaga.execute(submit, %{"bybit" => exchange},
                 request_opts: [plug: {Req.Test, stub}, timestamp_ms_override: @now]
               )

      assert client_id == submit.client_order_id
      assert {:error, %Error{type: :invalid_parameters}} = OptionSaga.execute(submit, %{})
      assert {:error, %Error{type: :invalid_parameters}} = Executor.execute(submit, %{})
    end
  end

  defp new_journal(approval) do
    OptionSaga.new(approval, now_ms: @now, max_approval_age_ms: @max_age_ms)
  end

  defp approval(overrides \\ []) do
    plan = %{
      legs: Keyword.get(overrides, :legs, [leg()]),
      hedge: Keyword.get(overrides, :hedge),
      venue_policy: :same_only,
      risk_targets: %{},
      hard_limits: %{}
    }

    %Result{
      status: Keyword.get(overrides, :status, :approved),
      observed_at: Keyword.get(overrides, :observed_at, @now),
      projected: %{},
      hedge: plan.hedge,
      margin_domains: [],
      cross_venue: nil,
      checks: [],
      violations: [],
      failures: [],
      plan: plan,
      strategy: %{}
    }
  end

  defp leg(overrides \\ []) do
    %{
      id: Keyword.get(overrides, :id, "option"),
      venue: "bybit",
      account: "demo",
      symbol: "BTC/USD:BTC-260131-100000-C",
      side: "buy",
      amount: 1.0,
      price: 0.01,
      type: "limit"
    }
  end

  defp hedge do
    %{
      candidate_id: "perp",
      venue: "bybit",
      account: "demo",
      symbol: "BTC/USDT:USDT",
      side: "sell",
      quantity: 0.001,
      signed_quantity: -0.001,
      residual_delta: 0.0,
      target_delta: 0.0,
      cross_venue?: false,
      feasible?: true,
      reason: nil
    }
  end

  defp leg_states(journal, command) do
    journal.legs
    |> Enum.find(&(&1.execution_id == command.execution_id))
    |> Map.fetch!(:transitions)
    |> Enum.map(& &1.state)
  end
end
