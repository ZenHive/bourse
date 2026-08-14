defmodule Bourse.OracleProvenance.MutationAdjudicationTest do
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.JsonDocument
  alias Bourse.OracleProvenance.MutationAdjudication
  alias Bourse.OracleProvenance.MutationAdjudication.Lifecycle
  alias Bourse.OracleProvenance.MutationAdjudication.Redaction
  alias Mix.Tasks.Ccxt.AuthorityCorpus

  doctest Redaction

  @register_path "priv/authority/deribit/mutation-adjudication.json"
  @plan_path "priv/authority/deribit/mutation-lifecycle-plan.json"
  @fixture_root "test/fixtures/provider_operations/deribit_mutations"
  @fixed_now ~U[2026-08-14 06:00:00Z]

  describe "the committed adjudication" do
    test "partitions every current-REST operation without dropping one" do
      %{register: register} = MutationAdjudication.load_reviewed!()
      denominator = register["denominator"]

      parts =
        ~w(task_556_operation_keys task_557_operation_keys adjudicated_operation_keys websocket_only_operation_keys)

      counts = Map.new(parts, &{&1, length(denominator[&1])})

      assert counts == %{
               "task_556_operation_keys" => 2,
               "task_557_operation_keys" => 95,
               "adjudicated_operation_keys" => 71,
               "websocket_only_operation_keys" => 10
             }

      assert Enum.sum(Map.values(counts)) == denominator["provider_count"]
      assert denominator["provider_count"] == 178

      all = Enum.flat_map(parts, &denominator[&1])
      assert length(Enum.uniq(all)) == length(all)
      assert Enum.all?(all, &String.starts_with?(&1, "GET /api/v2/"))
    end

    test "judges every adjudicated operation explicitly, and value-moving ones are never approved" do
      %{register: register} = MutationAdjudication.load_reviewed!()

      Enum.each(register["operations"], fn operation ->
        review = operation["execution_review"]
        assert review["classification"] == "reviewed"
        assert review["decision"] in ~w(approved refused)
        assert review["reachability"] in ~w(safe unsafe unreachable)
        assert review["safety"] in ~w(safe unsafe not_applicable)
        assert String.length(review["rationale"]) >= 40

        if review["decision"] == "approved" do
          assert review["value_movement"] == "none"
          assert review["durability"] != "persistent"
        else
          assert is_binary(review["ledger_ref"])
        end
      end)

      approved =
        register["operations"]
        |> Enum.filter(&(&1["execution_review"]["decision"] == "approved"))
        |> Enum.map(& &1["operation_id"])
        |> Enum.sort()

      assert approved == ~w(private/buy private/cancel private/cancel_by_label private/edit private/edit_by_label
                            private/sell)
    end

    test "keeps every irreversible or value-moving family refused with an actionable ledger entry" do
      %{register: register} = MutationAdjudication.load_reviewed!()
      ledger = File.read!("docs/prod-verification-ledger.md")
      by_id = Map.new(register["operations"], &{&1["operation_id"], &1["execution_review"]})

      for operation_id <- ~w(private/withdraw private/submit_transfer_to_user private/create_api_key
                             private/remove_api_key private/create_subaccount private/remove_subaccount
                             private/add_to_address_book private/create_deposit_address private/cancel_all
                             private/close_position public/auth) do
        review = Map.fetch!(by_id, operation_id)
        assert review["decision"] == "refused", "#{operation_id} must never be approved"
        assert review["reachability"] in ~w(unsafe unreachable)
        assert String.contains?(ledger, review["ledger_ref"])
      end
    end

    test "records the WebSocket-only prose/tag disagreement instead of trusting the tag alone" do
      %{register: register} = MutationAdjudication.load_reviewed!()
      by_id = Map.new(register["operations"], &{&1["operation_id"], &1})

      tagged = Map.fetch!(by_id, "private/subscribe")
      assert tagged["provider"]["qualifiers"] == ["websocket_only"]
      assert tagged["execution_review"]["reachability"] == "unreachable"

      # The provider's prose declares these WebSocket-only while the OpenAPI tag
      # set does not, so the tag alone under-reports REST-unreachable operations.
      untagged = Map.fetch!(by_id, "private/enable_cancel_on_disconnect")
      assert untagged["provider"]["qualifiers"] == []
      assert untagged["execution_review"]["reachability"] == "unreachable"
      assert untagged["execution_review"]["safety"] == "not_applicable"
    end

    test "binds its denominator to the recorded upstream drift rather than an unread pin" do
      %{register: register} = MutationAdjudication.load_reviewed!()
      binding = register["source_binding"]
      drift = JsonDocument.decode_file!(binding["drift_record"])

      assert drift["pin_action"] == "not_refreshed"
      refute drift["pinned"]["retrievable"]
      assert drift["observed"]["sha256"] == binding["denominator_enumerated_from"]["sha256"]
      assert drift["pinned"]["sha256"] == binding["pinned_revision_sha256"]
      assert drift["pinned"]["sha256"] != drift["observed"]["sha256"]
    end
  end

  describe "the committed reality" do
    test "keeps relation, runtime scope, evidence, reachability and safety independent" do
      corpus = MutationAdjudication.validate!()
      facts = MutationAdjudication.facts!()

      assert length(facts) == 81
      assert Enum.all?(facts, &(&1["contract_scope"] == "current_rest"))

      buy = Enum.find(corpus.manifest["operations"], &(&1["operation_id"] == "private/buy"))
      assert buy["evidence"] == "verified"
      assert buy["reachability"] == "safe"
      assert buy["relation"] == "shared"
      assert buy["runtime_scope"] == "unified"

      # Unsafe never means absent, unsupported or deleted: the operation keeps a
      # row with its own independent relation and runtime scope.
      withdraw = Enum.find(corpus.manifest["operations"], &(&1["operation_id"] == "private/withdraw"))
      assert withdraw["evidence"] == "unverified"
      assert withdraw["reachability"] == "unsafe"
      assert withdraw["relation"] == "shared"
      assert withdraw["runtime_scope"] == "unified"

      unreachable = Enum.find(corpus.manifest["operations"], &(&1["operation_id"] == "public/hello"))
      assert unreachable["reachability"] == "unreachable"
      assert unreachable["safety"] == "not_applicable"
      assert unreachable["relation"] == "shared"
    end

    test "verifies exactly the mutations the reviewed lifecycle actually exercised" do
      %{manifest: manifest} = MutationAdjudication.validate!()

      verified =
        manifest["operations"]
        |> Enum.filter(&(&1["evidence"] == "verified"))
        |> Enum.map(& &1["operation_id"])
        |> Enum.sort()

      assert verified == ~w(private/buy private/cancel)
      assert Enum.all?(manifest["operations"], &(&1["decision"] != "refused" or &1["capture_ids"] == []))
    end

    test "records a reversible lifecycle with setup, cleanup and an idempotent final state" do
      corpus = MutationAdjudication.validate!()
      [lifecycle] = corpus.manifest["lifecycles"]

      assert lifecycle["operation_id"] == "private/buy"
      assert lifecycle["reversal_operation_id"] == "private/cancel"
      assert lifecycle["cleanup_outcome"] == "completed"
      assert lifecycle["final_state"] == "cancelled"

      placed = body(corpus.recordings["place_order"])
      assert get_in(placed, ["result", "order", "order_state"]) == "open"
      assert get_in(placed, ["result", "order", "post_only"]) == true
      assert get_in(placed, ["result", "order", "filled_amount"]) == 0.0

      cancelled = body(corpus.recordings["cancel_order"])
      assert get_in(cancelled, ["result", "order_state"]) == "cancelled"

      final = body(corpus.recordings["final_state"])
      assert get_in(final, ["result", "order_state"]) == "cancelled"
      assert get_in(final, ["result", "filled_amount"]) == 0.0
    end

    test "pins safe provider failures on their documented domain meaning" do
      corpus = MutationAdjudication.validate!()
      documented = MutationAdjudication.documented_codes("priv/authority/deribit/errors.json")

      repeat = body(corpus.recordings["cancel_again"])
      assert get_in(repeat, ["error", "code"]) == 11_044
      assert get_in(repeat, ["error", "message"]) == "not_open_order"
      assert hd(Map.fetch!(documented, "11044")) =~ "not open order"
      assert corpus.recordings["cancel_again"]["response"]["http_status"] == 400

      # The venue answers the JSON-RPC invalid-params code with a parameter-level
      # reason rather than the dedicated price_wrong_tick code, so the assertion
      # pins the reason it actually gives.
      off_tick = body(corpus.recordings["reject_wrong_tick"])
      assert get_in(off_tick, ["error", "code"]) == -32_602
      assert get_in(off_tick, ["error", "data", "param"]) == "price"
      assert get_in(off_tick, ["error", "data", "reason"]) == "must conform to tick size"
      assert Map.has_key?(documented, "-32602")

      for capture_id <- ~w(cancel_again reject_wrong_tick) do
        assert corpus.recordings[capture_id]["role"] in ~w(idempotent_final_state failure_probe)
      end
    end

    test "redacts credential material out of every private capture" do
      corpus = MutationAdjudication.validate!()

      authenticated =
        Enum.filter(corpus.recordings, fn {_id, fixture} ->
          "authorization" in fixture["request"]["redacted_headers"]
        end)

      assert length(authenticated) == 6

      Enum.each(authenticated, fn {id, fixture} ->
        header = Enum.find(fixture["request"]["headers"], &(&1["name"] == "authorization"))
        assert header["value"] == Redaction.mask(), "#{id} committed a live authorization header"
        assert Redaction.violations(fixture) == []
      end)

      placed = corpus.recordings["place_order"]
      assert placed["response"]["redacted_body_paths"] == ["$.result.order.user_id"]
      assert get_in(body(placed), ["result", "order", "user_id"]) == Redaction.mask()
    end
  end

  describe "the execution boundary" do
    test "refuses an unadjudicated, refused, unsafe, unreachable or value-moving operation" do
      %{register: register, plan: plan} = MutationAdjudication.load_reviewed!()
      [lifecycle] = plan["lifecycles"]
      act = Enum.find(lifecycle["steps"], &(&1["role"] == "act"))

      assert :ok = MutationAdjudication.authorize(register, lifecycle, act)

      for {operation_id, reason} <- [
            {"private/not_a_real_method", :unadjudicated},
            {"private/withdraw", :refused_by_review},
            {"private/cancel_all", :refused_by_review},
            {"private/create_api_key", :refused_by_review},
            {"public/auth", :refused_by_review},
            # A WebSocket-only path is not even classified as a REST mutation, so
            # it is refused one step earlier than a refused mutation is.
            {"private/subscribe", :not_a_mutation}
          ] do
        step = Map.put(act, "operation_id", operation_id)
        assert {:error, {:refused, ^reason}} = MutationAdjudication.authorize(register, lifecycle, step)
      end

      unclassified = Map.put(act, "role", "sabotage")

      assert {:error, {:refused, :unclassified_role}} =
               MutationAdjudication.authorize(register, lifecycle, unclassified)
    end

    test "refuses a mutation smuggled in as a non-mutating step" do
      %{register: register, plan: plan} = MutationAdjudication.load_reviewed!()
      [lifecycle] = plan["lifecycles"]
      observe = Enum.find(lifecycle["steps"], &(&1["role"] == "observe"))

      assert :ok = MutationAdjudication.authorize(register, lifecycle, observe)

      smuggled = Map.put(observe, "operation_id", "private/buy")
      assert {:error, {:refused, :mutating}} = MutationAdjudication.authorize(register, lifecycle, smuggled)

      unknown = Map.put(observe, "operation_id", "private/not_a_real_read")
      assert {:error, {:refused, :unadjudicated}} = MutationAdjudication.authorize(register, lifecycle, unknown)
    end

    test "refuses every mutating step when the lifecycle itself is not approved" do
      %{register: register, plan: plan} = MutationAdjudication.load_reviewed!()
      [lifecycle] = plan["lifecycles"]
      unapproved = put_in(lifecycle, ["review", "decision"], "pending")

      for step <- lifecycle["steps"], step["role"] in ~w(act cleanup idempotent_final_state failure_probe) do
        assert {:error, {:refused, :no_reviewed_lifecycle}} =
                 MutationAdjudication.authorize(register, unapproved, step)
      end
    end

    test "refuses a relabelled operation before any request reaches the adapter" do
      root = temporary_directory("refused-before-request")
      register = JsonDocument.decode_file!(@register_path)

      relabelled =
        update_in(register["operations"], fn operations ->
          Enum.map(operations, fn operation ->
            if operation["operation_id"] == "private/buy" do
              operation
              |> put_in(["execution_review", "decision"], "refused")
              |> put_in(["execution_review", "safety"], "unsafe")
              |> put_in(["execution_review", "reachability"], "unsafe")
              |> put_in(
                ["execution_review", "ledger_ref"],
                "deribit — session credential issuance (task 558, filed 2026-08-14)"
              )
            else
              operation
            end
          end)
        end)

      register_path = Path.join(root, "register.json")
      File.write!(register_path, Jason.encode!(relabelled, pretty: true))

      plan = @plan_path |> JsonDocument.decode_file!() |> Map.put("adjudication", register_path)
      plan_path = Path.join(root, "plan.json")
      File.write!(plan_path, Jason.encode!(plan, pretty: true))

      assert_raise ArgumentError, ~r/step order_place_cancel\/place_order refused: refused_by_review/, fn ->
        Lifecycle.capture!(Path.join(root, "output"),
          register_path: register_path,
          plan_path: plan_path,
          request_fun: fn _request -> flunk("a refused operation reached the request adapter") end,
          credentials: stub_credentials(),
          now: fn -> @fixed_now end
        )
      end
    end

    test "replays the committed lifecycle deterministically" do
      root = temporary_directory("replay")

      manifest =
        Lifecycle.capture!(root,
          request_fun: replay_fun(),
          credentials: stub_credentials(),
          now: fn -> @fixed_now end,
          session_label: "bourse-t558-replay"
        )

      assert [%{"cleanup_outcome" => "completed", "final_state" => "cancelled"}] = manifest["lifecycles"]
      assert length(manifest["recordings"]) == 8
      assert MutationAdjudication.validate!(root: root, manifest_path: Path.join(root, "_manifest.json"))
    end

    test "runs the reviewed compensating call and says so when a later step fails" do
      root = temporary_directory("cleanup-loud")
      replay = replay_fun()

      failing = fn request ->
        if String.contains?(request["url"], "/private/get_order_state") and not String.contains?(request["url"], "x") do
          {:error, :simulated_network_loss}
        else
          replay.(request)
        end
      end

      error =
        assert_raise ArgumentError, fn ->
          Lifecycle.capture!(root,
            request_fun: failing,
            credentials: stub_credentials(),
            now: fn -> @fixed_now end,
            session_label: "bourse-t558-cleanup"
          )
        end

      assert Exception.message(error) =~ "simulated_network_loss"
      assert Exception.message(error) =~ "Reviewed cleanup private/cancel was retried"
      assert Exception.message(error) =~ "cancelled"
    end

    test "cancels a placed order when the acting step's observation does not match the review" do
      root = temporary_directory("act-observation-cleanup")
      replay = replay_fun()
      seen = :ets.new(:act_observation_cleanup, [:set, :public])

      failing = fn request ->
        cond do
          String.contains?(request["url"], "/private/buy?") and on_tick?(request) ->
            {:ok,
             %{
               status: 200,
               body:
                 Jason.encode!(%{
                   "result" => %{
                     "order" => %{
                       "order_id" => "113510807523",
                       "order_state" => "untriggered",
                       "direction" => "buy",
                       "order_type" => "limit",
                       "post_only" => true,
                       "filled_amount" => 0.0,
                       "instrument_name" => "BTC-PERPETUAL"
                     }
                   }
                 })
             }}

          String.contains?(request["url"], "/private/cancel?") ->
            :ets.insert(seen, {:cancel, request["url"]})
            replay.(request)

          true ->
            replay.(request)
        end
      end

      error =
        assert_raise ArgumentError, fn ->
          Lifecycle.capture!(root,
            request_fun: failing,
            credentials: stub_credentials(),
            now: fn -> @fixed_now end,
            session_label: "bourse-t558-act-obs"
          )
        end

      message = Exception.message(error)
      assert message =~ ~s(order_state is "untriggered", reviewed as "open")
      assert message =~ "Reviewed cleanup private/cancel was retried"
      assert message =~ "cancelled"
      assert [{:cancel, url}] = :ets.lookup(seen, :cancel)
      assert url =~ "order_id=113510807523"
    end

    test "shouts when the compensating call cannot even be built" do
      root = temporary_directory("cleanup-uncallable")
      replay = replay_fun()

      failing = fn request ->
        cond do
          String.contains?(request["url"], "/private/get_order_state") -> {:error, :simulated_network_loss}
          String.contains?(request["url"], "/private/cancel?") -> throw(:cleanup_threw)
          true -> replay.(request)
        end
      end

      error =
        assert_raise ArgumentError, fn ->
          Lifecycle.capture!(root,
            request_fun: failing,
            credentials: stub_credentials(),
            now: fn -> @fixed_now end,
            session_label: "bourse-t558-uncallable"
          )
        end

      message = Exception.message(error)
      assert message =~ "🚨 Reviewed cleanup private/cancel could not even be built"
      assert message =~ "cleanup_threw"
      assert message =~ "bourse-t558-uncallable"
    end

    test "shouts when the compensating call itself fails and names what is left behind" do
      root = temporary_directory("cleanup-failed")
      replay = replay_fun()

      failing = fn request ->
        cond do
          String.contains?(request["url"], "/private/get_order_state") -> {:error, :simulated_network_loss}
          String.contains?(request["url"], "/private/cancel?") -> {:error, :simulated_cleanup_loss}
          true -> replay.(request)
        end
      end

      error =
        assert_raise ArgumentError, fn ->
          Lifecycle.capture!(root,
            request_fun: failing,
            credentials: stub_credentials(),
            now: fn -> @fixed_now end,
            session_label: "bourse-t558-orphan"
          )
        end

      message = Exception.message(error)
      assert message =~ "🚨 Reviewed cleanup private/cancel FAILED"
      assert message =~ "simulated_cleanup_loss"
      assert message =~ "bourse-t558-orphan"
      assert message =~ "test.deribit.com"
    end
  end

  describe "the parameter bindings" do
    test "refuse an unreviewed, incomplete, out-of-order or non-numeric binding" do
      for {binding, pattern} <- [
            {%{"literal" => 42}, ~r/carries an unreviewed parameter binding/},
            {%{"bind" => "order_id"}, ~r/carries an incomplete binding/},
            {%{"bind" => "order_id", "from_step" => "final_state", "path" => ["result", "order_state"]},
             ~r/reads step final_state, which has not run/},
            {%{"bind" => "order_id", "from_step" => "setup_ticker", "path" => ["result", "nope"]},
             ~r/found no result\.nope in step setup_ticker/}
          ] do
        assert_raise ArgumentError, pattern, fn -> run_with_binding(binding) end
      end

      non_numeric = %{
        "bind" => "unfillable_bid",
        "from_step" => "setup_ticker",
        "path" => ["result", "instrument_name"],
        "tick_from_step" => "setup_instrument",
        "tick_path" => ["result", "tick_size"]
      }

      assert_raise ArgumentError, ~r/resolved "BTC-PERPETUAL" where a number was reviewed/, fn ->
        run_with_binding(non_numeric)
      end
    end

    test "refuse a non-positive tick size rather than dividing by it" do
      root = temporary_directory("zero-tick")
      plan = JsonDocument.decode_file!(@plan_path)

      changed =
        put_in(plan, ["lifecycles", Access.at(0), "steps", Access.at(0), "expected", "assertions"], [
          %{"path" => ["result", "tick_size"], "equals" => 0}
        ])

      plan_path = Path.join(root, "plan.json")
      File.write!(plan_path, Jason.encode!(changed, pretty: true))
      replay = replay_fun()

      zero_tick = fn request ->
        if String.contains?(request["url"], "/public/get_instrument"),
          do: {:ok, %{status: 200, body: ~s({"result":{"instrument_name":"BTC-PERPETUAL","tick_size":0}})}},
          else: replay.(request)
      end

      assert_raise ArgumentError, ~r/resolved a non-positive tick size/, fn ->
        Lifecycle.capture!(Path.join(root, "output"),
          plan_path: plan_path,
          request_fun: zero_tick,
          credentials: stub_credentials(),
          now: fn -> @fixed_now end
        )
      end
    end

    test "refuse a transport result that is neither a response nor an error" do
      root = temporary_directory("bad-transport")

      assert_raise ArgumentError, ~r/returned an invalid transport result: :surprise/, fn ->
        Lifecycle.capture!(root,
          request_fun: fn _request -> :surprise end,
          credentials: stub_credentials(),
          now: fn -> @fixed_now end
        )
      end
    end

    test "refuse an HTTP status the review did not expect" do
      root = temporary_directory("bad-status")

      assert_raise ArgumentError, ~r/HTTP 503 where the review expects 200/, fn ->
        Lifecycle.capture!(root,
          request_fun: fn _request -> {:ok, %{status: 503, body: ~s({"result":{}})}} end,
          credentials: stub_credentials(),
          now: fn -> @fixed_now end
        )
      end
    end
  end

  describe "credentials" do
    test "fail loudly with the exact exports when the testnet key is absent" do
      saved = Map.new(~w(DERIBIT_TESTNET_API_KEY DERIBIT_TESTNET_API_SECRET), &{&1, System.get_env(&1)})
      Enum.each(Map.keys(saved), &System.delete_env/1)

      on_exit(fn ->
        Enum.each(saved, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      error =
        assert_raise ArgumentError, fn ->
          Lifecycle.capture!(temporary_directory("missing-creds"),
            request_fun: fn _request -> flunk("a credential-less run reached the request adapter") end,
            now: fn -> @fixed_now end
          )
        end

      message = Exception.message(error)
      assert message =~ "deribit testnet credentials are missing: DERIBIT_TESTNET_API_KEY, DERIBIT_TESTNET_API_SECRET"
      assert message =~ "export DERIBIT_TESTNET_API_KEY="
      assert message =~ "https://test.deribit.com/account/BTC/api"

      System.put_env("DERIBIT_TESTNET_API_KEY", "env-key")
      System.put_env("DERIBIT_TESTNET_API_SECRET", "env-secret")
      root = temporary_directory("env-creds")

      assert %{"corpus" => "provider_mutation_reality"} =
               Lifecycle.capture!(root, request_fun: replay_fun(), now: fn -> @fixed_now end)
    end
  end

  describe "redaction" do
    test "leaves an insensitive header alone and reports what it can mask" do
      assert "authorization" in Redaction.sensitive_headers()

      request = %{"headers" => [%{"name" => "Accept", "value" => "application/json"}]}
      assert Redaction.redact_request(request) == Map.put(request, "redacted_headers", [])

      headerless = %{"method" => "GET"}
      assert Redaction.redact_request(headerless) == Map.put(headerless, "redacted_headers", [])

      malformed = %{"headers" => [%{"name" => 42, "value" => "x"}, "not-a-header"]}
      assert Redaction.redact_request(malformed)["redacted_headers"] == []
      assert Redaction.violations(malformed) == []
    end
  end

  describe "corpus tampering" do
    test "a ledger-only operation cannot be relabelled verified" do
      root = temporary_directory("mislabel-verified")
      File.cp_r!(@fixture_root, root)
      manifest_path = Path.join(root, "_manifest.json")
      manifest = JsonDocument.decode_file!(manifest_path)

      index = Enum.find_index(manifest["operations"], &(&1["operation_id"] == "private/withdraw"))

      tampered =
        manifest
        |> put_in(["operations", Access.at(index), "evidence"], "verified")
        |> put_in(["operations", Access.at(index), "capture_ids"], ["place_order"])

      File.write!(manifest_path, Jason.encode!(tampered, pretty: true))

      assert_raise ArgumentError, ~r/operation facts differ from the register and captures/, fn ->
        MutationAdjudication.validate!(root: root, manifest_path: manifest_path)
      end
    end

    test "a capture that still carries a live authorization header is rejected" do
      root = temporary_directory("unmasked-header")
      File.cp_r!(@fixture_root, root)
      path = Path.join([root, "deribit", "place_order.json"])
      fixture = JsonDocument.decode_file!(path)

      leaked =
        update_in(fixture["request"]["headers"], fn headers ->
          Enum.map(headers, fn header ->
            if header["name"] == "authorization",
              do: Map.put(header, "value", "deri-hmac-sha256 id=live,ts=1,sig=deadbeef,nonce=2"),
              else: header
          end)
        end)

      write_capture!(root, path, leaked)

      assert_raise ArgumentError, ~r/carries credential material at \$\.request\.headers\[1\]/, fn ->
        MutationAdjudication.validate!(root: root, manifest_path: Path.join(root, "_manifest.json"))
      end
    end

    test "a capture whose observation drifts from the review is rejected" do
      root = temporary_directory("observation-drift")
      File.cp_r!(@fixture_root, root)
      path = Path.join([root, "deribit", "cancel_again.json"])
      fixture = JsonDocument.decode_file!(path)

      relabelled =
        put_in(
          fixture,
          ["response", "raw_body"],
          Jason.encode!(%{"error" => %{"code" => 10_004, "message" => "order_not_found"}})
        )

      write_capture!(root, path, relabelled)

      assert_raise ArgumentError, ~r/provider error code is 10004, reviewed as 11044/, fn ->
        MutationAdjudication.validate!(root: root, manifest_path: Path.join(root, "_manifest.json"))
      end
    end

    test "a plan that probes an undocumented provider error is rejected" do
      root = temporary_directory("undocumented-error")
      plan = JsonDocument.decode_file!(@plan_path)

      changed =
        put_in(plan, ["lifecycles", Access.at(0), "steps", Access.at(6), "expected", "error_code"], 987_654)

      plan_path = Path.join(root, "plan.json")
      File.write!(plan_path, Jason.encode!(changed, pretty: true))

      assert_raise ArgumentError, ~r/absent from the provider error authority/, fn ->
        MutationAdjudication.load_reviewed!(plan_path: plan_path)
      end
    end

    test "a lifecycle without a cleanup step is rejected" do
      root = temporary_directory("no-cleanup")
      plan = JsonDocument.decode_file!(@plan_path)

      changed =
        update_in(plan["lifecycles"], fn [lifecycle] ->
          [update_in(lifecycle["steps"], fn steps -> Enum.reject(steps, &(&1["role"] == "cleanup")) end)]
        end)

      plan_path = Path.join(root, "plan.json")
      File.write!(plan_path, Jason.encode!(changed, pretty: true))

      assert_raise ArgumentError, ~r/lifecycle order_place_cancel has no cleanup step/, fn ->
        MutationAdjudication.load_reviewed!(plan_path: plan_path)
      end
    end

    test "a capture identifier cannot escape the corpus root" do
      root = temporary_directory("escaping-capture")
      plan = JsonDocument.decode_file!(@plan_path)

      changed = put_in(plan, ["lifecycles", Access.at(0), "steps", Access.at(0), "step_id"], "../escape")
      plan_path = Path.join(root, "plan.json")
      File.write!(plan_path, Jason.encode!(changed, pretty: true))

      assert_raise ArgumentError, ~r/names a capture that is not a safe path component/, fn ->
        MutationAdjudication.load_reviewed!(plan_path: plan_path)
      end

      assert_raise ArgumentError, ~r/resolves outside its corpus root/, fn ->
        MutationAdjudication.resolve_inside_root!(root, "../outside.json")
      end
    end

    test "an operation dropped from the denominator is rejected rather than silently deleted" do
      root = temporary_directory("shrunk-denominator")
      register = JsonDocument.decode_file!(@register_path)

      shrunk =
        update_in(register["denominator"]["adjudicated_operation_keys"], fn keys ->
          Enum.reject(keys, &(&1 == "GET /api/v2/private/withdraw"))
        end)

      register_path = Path.join(root, "register.json")
      File.write!(register_path, Jason.encode!(shrunk, pretty: true))

      assert_raise ArgumentError, ~r/denominator partitions cover 177 of 178/, fn ->
        MutationAdjudication.load_reviewed!(register_path: register_path)
      end
    end
  end

  # Binding shapes are resolved at execution time, not at plan-validation time,
  # so the only way to exercise a bad one is to run the lifecycle with it.
  defp run_with_binding(binding) do
    root = temporary_directory("binding-#{System.unique_integer([:positive])}")
    plan = JsonDocument.decode_file!(@plan_path)
    changed = put_in(plan, ["lifecycles", Access.at(0), "steps", Access.at(2), "params", "price"], binding)
    plan_path = Path.join(root, "plan.json")
    File.write!(plan_path, Jason.encode!(changed, pretty: true))

    Lifecycle.capture!(Path.join(root, "output"),
      plan_path: plan_path,
      request_fun: replay_fun(),
      credentials: stub_credentials(),
      now: fn -> @fixed_now end
    )
  end

  defp body(fixture), do: Jason.decode!(fixture["response"]["raw_body"])

  defp write_capture!(root, path, fixture) do
    contents = Jason.encode!(fixture, pretty: true) <> "\n"
    File.write!(path, contents)
    manifest_path = Path.join(root, "_manifest.json")
    manifest = JsonDocument.decode_file!(manifest_path)
    capture_id = fixture["capture_id"]
    index = Enum.find_index(manifest["recordings"], &(&1["capture_id"] == capture_id))

    updated =
      manifest
      |> put_in(["recordings", Access.at(index), "bytes"], byte_size(contents))
      |> put_in(["recordings", Access.at(index), "sha256"], AuthorityCorpus.sha256(contents))

    File.write!(manifest_path, Jason.encode!(updated, pretty: true))
  end

  # Three operations appear twice in one lifecycle, so the adapter is keyed by
  # capture id and resolves each repeat the way the venue distinguishes it: the
  # failure probe by its off-tick price, the repeats by call order.
  defp replay_fun do
    counters = :ets.new(:mutation_replay, [:set, :public])

    fn request ->
      response = request |> replay_capture_id(counters) |> capture() |> Map.fetch!("response")
      {:ok, %{status: response["http_status"], body: response["raw_body"]}}
    end
  end

  defp replay_capture_id(request, counters) do
    operation_id = request["url"] |> URI.parse() |> Map.fetch!(:path) |> String.replace_prefix("/api/v2/", "")

    case operation_id do
      "public/get_instrument" -> "setup_instrument"
      "public/ticker" -> "setup_ticker"
      "private/buy" -> if(on_tick?(request), do: "place_order", else: "reject_wrong_tick")
      "private/get_order_state" -> Enum.at(~w(observe_open final_state), bump(counters, :order_state))
      "private/cancel" -> Enum.at(~w(cancel_order cancel_again), bump(counters, :cancel))
    end
  end

  defp on_tick?(request) do
    price =
      request["url"]
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("price")
      |> String.to_float()

    price / 0.5 == Float.round(price / 0.5)
  end

  defp capture(capture_id) do
    JsonDocument.decode_file!(Path.join([@fixture_root, "deribit", "#{capture_id}.json"]))
  end

  defp bump(counters, key), do: :ets.update_counter(counters, key, {2, 1}, {key, -1})

  defp stub_credentials do
    Credentials.new!(api_key: "test-key", secret: "test-secret")
  end

  defp temporary_directory(label) do
    path = Path.join(System.tmp_dir!(), "mutation-adjudication-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
