defmodule Bourse.Signing.LighterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.Signing.Lighter
  alias Bourse.Signing.Lighter.Worker
  alias Bourse.Signing.Request
  alias Bourse.Signing.SignedRequest
  alias Bourse.Test.RequestCollector

  @private_key "07000000000000000300000000000000000000000000000000000000000000000000000000000000"
  @other_private_key "08000000000000000300000000000000000000000000000000000000000000000000000000000000"

  setup do
    on_exit(fn ->
      Lighter.terminate_helper(credentials(@private_key), helper_config("normal"))
      Lighter.terminate_helper(credentials(@other_private_key), helper_config("normal"))
    end)
  end

  test "routes auth through one per-key Port without leaking the key" do
    credentials = credentials(@private_key)
    request = request(%{"account_index" => 1, "auth_deadline" => 1_800_000_000})
    config = helper_config("normal")

    assert %SignedRequest{} = signed = Lighter.sign(request, credentials, config)
    assert signed.url == "/api/v1/accountLimits?account_index=1"
    assert signed.headers == [{"Authorization", "1800000000:1:0:fake-signature"}]
    assert signed.body == nil

    assert {:ok, %{pid: pid, os_pid: os_pid}} = Lighter.helper_info(credentials, config)
    assert is_pid(pid)
    assert is_integer(os_pid)
    assert {:ok, %{pid: ^pid}} = Lighter.helper_info(credentials, config)
    assert %SignedRequest{} = Lighter.sign(request, credentials, config)

    refute inspect(credentials) =~ @private_key
    refute inspect(signed) =~ @private_key
    refute inspect(:sys.get_status(pid)) =~ @private_key
    refute inspect(:sys.get_state(pid)) =~ @private_key
  end

  test "isolates distinct keys in distinct helpers" do
    first = credentials(@private_key)
    second = credentials(@other_private_key)
    config = helper_config("normal")

    assert %SignedRequest{} = Lighter.sign(request(), first, config)
    assert %SignedRequest{} = Lighter.sign(request(), second, config)
    assert {:ok, %{pid: first_pid}} = Lighter.helper_info(first, config)
    assert {:ok, %{pid: second_pid}} = Lighter.helper_info(second, config)
    refute first_pid == second_pid
  end

  test "helper crash does not terminate the VM and the next request restarts it" do
    credentials = credentials(@private_key)
    parent = self()

    log =
      capture_log(fn ->
        assert {:error, {:lighter_signing, :helper_terminated}} =
                 Lighter.sign(request(), credentials, helper_config("crash_on_auth"))

        assert Process.alive?(parent)
      end)

    refute log =~ @private_key
    assert_eventually(fn -> Lighter.helper_info(credentials, helper_config("normal")) == {:error, :not_running} end)
    assert %SignedRequest{} = Lighter.sign(request(), credentials, helper_config("normal"))
  end

  test "helper keeps non-closed stdout write failures loud" do
    {output, status} =
      System.cmd(System.find_executable("elixir"), helper_config("write_error").helper_args, stderr_to_stdout: true)

    assert status == 1
    assert output =~ "Erlang error: :enospc"
  end

  test "helper treats a closed stdout as an ordinary end of stream" do
    {output, status} =
      System.cmd(System.find_executable("elixir"), helper_config("write_terminated").helper_args, stderr_to_stdout: true)

    assert status == 0
    refute output =~ "Erlang error"
  end

  test "terminating the temporary owner removes the key and its helper" do
    credentials = credentials(@private_key)
    config = helper_config("normal")

    assert %SignedRequest{} = Lighter.sign(request(), credentials, config)
    assert {:ok, %{pid: first_pid}} = Lighter.helper_info(credentials, config)
    monitor = Process.monitor(first_pid)

    assert :ok = Lighter.terminate_helper(credentials, config)
    assert_receive {:DOWN, ^monitor, :process, ^first_pid, :shutdown}
    assert {:error, :not_running} = Lighter.helper_info(credentials, config)

    assert %SignedRequest{} = Lighter.sign(request(), credentials, config)
    assert {:ok, %{pid: second_pid}} = Lighter.helper_info(credentials, config)
    refute first_pid == second_pid
  end

  test "translates initialization, protocol, and credential failures without native text" do
    credentials = credentials(@private_key)

    assert {:error, {:lighter_signing, :client_initialization_failed}} =
             Lighter.sign(request(), credentials, helper_config("init_error"))

    assert {:error, {:lighter_signing, :protocol_error}} =
             Lighter.sign(request(), credentials, helper_config("bad_response"))

    assert {:error, {:lighter_signing, :invalid_credentials}} =
             Lighter.sign(request(), %{credentials | secret: "not-a-key"}, helper_config("normal"))

    assert {:error, {:lighter_signing, :invalid_configuration}} =
             Lighter.sign(request(), %{credentials | api_key: "not-an-index"}, helper_config("normal"))

    assert {:error, {:lighter_signing, :invalid_credentials}} =
             Lighter.sign(request(), %{credentials | secret: nil}, helper_config("normal"))

    assert {:error, {:lighter_signing, :invalid_configuration}} =
             Lighter.sign(request(%{}), %{credentials | uid: nil}, helper_config("normal"))

    assert {:error, {:lighter_signing, :invalid_configuration}} =
             Lighter.sign(request(), credentials, %{helper_config("normal") | base_url: ""})

    assert {:error, {:lighter_signing, :invalid_configuration}} =
             Lighter.sign(request(), credentials, %{helper_config("normal") | helper_path: 123})

    assert {:error, {:lighter_signing, :invalid_configuration}} =
             Lighter.sign(request(), credentials, Map.put(helper_config("normal"), :chain_id, 0))
  end

  test "exposes only whitelisted transaction signing operations" do
    credentials = credentials(@private_key)
    config = helper_config("normal")

    assert {:ok,
            %{
              tx_type: 14,
              tx_info: ~s({"signature":"fake-signature"}),
              tx_hash: "fake-hash",
              message_to_sign: "fake-message"
            }} =
             Lighter.sign_transaction(:cancel_order, cancel_order(), credentials, config)

    assert {:error, {:lighter_signing, :invalid_argument}} =
             Lighter.sign_transaction(:withdraw, %{}, credentials, config)
  end

  test "signed transaction requests discard caller-owned wire payloads" do
    request = %Request{
      method: :post,
      path: "/api/v1/sendTx",
      body: "caller-body",
      params: %{
        "__bourse_lighter_transaction_operation" => "create_order",
        "__bourse_lighter_transaction_params" => create_order(),
        "tx_type" => 255,
        "tx_info" => ~s({"signature":"caller-signature"}),
        "signature" => "caller-signature"
      }
    }

    assert %SignedRequest{url: "/api/v1/sendTx", method: :post, headers: headers, body: body} =
             Lighter.sign(request, credentials(@private_key), helper_config("normal"))

    assert headers == [{"Content-Type", "application/x-www-form-urlencoded"}]

    assert URI.decode_query(body) == %{
             "tx_info" => ~s({"signature":"fake-signature"}),
             "tx_type" => "14"
           }

    refute body =~ "caller-signature"
  end

  test "signed transaction requests reject unowned operations and missing typed params" do
    base = %Request{method: :post, path: "/api/v1/sendTx", body: nil, params: %{}}

    assert {:error, {:lighter_signing, :invalid_configuration}} =
             Lighter.sign(
               %{base | params: %{"__bourse_lighter_transaction_operation" => "withdraw"}},
               credentials(@private_key),
               helper_config("normal")
             )

    assert {:error, {:lighter_signing, :invalid_configuration}} =
             Lighter.sign(
               %{base | params: %{"__bourse_lighter_transaction_operation" => "create_order"}},
               credentials(@private_key),
               helper_config("normal")
             )
  end

  test "accepts explicit identity options and a prefixed private key" do
    credentials = %{credentials("0x" <> @private_key) | api_key: nil, uid: nil}

    config =
      "normal"
      |> helper_config()
      |> Map.put(:exchange_options, %{"apiKeyIndex" => 0, "accountIndex" => 1, "chainId" => 304})

    assert %SignedRequest{} = Lighter.sign(request(%{"auth_deadline" => "invalid"}), credentials, config)
  end

  test "uses Lighter's testnet chain for sandbox transaction signatures" do
    credentials = credentials(@private_key)
    config = "expect_testnet_chain" |> helper_config() |> Map.put(:testnet, true)

    on_exit(fn -> Lighter.terminate_helper(credentials, config) end)

    assert %SignedRequest{} = Lighter.sign(request(), credentials, config)
  end

  test "reports unavailable helper and preserves request bodies" do
    credentials = credentials(@private_key)
    missing_config = %{helper_config("normal") | helper_path: "/definitely/missing/lighter-helper"}

    assert {:error, {:lighter_signing, :helper_unavailable}} =
             Lighter.sign(request(), credentials, missing_config)

    body_request = %Request{method: :post, path: "/api/v1/notificationAck", body: "{}", params: %{"account_index" => 1}}

    assert %SignedRequest{url: "/api/v1/notificationAck", body: "{}"} =
             Lighter.sign(body_request, credentials, helper_config("normal"))
  end

  test "public Lighter market data bypasses the private signer" do
    stub = {__MODULE__, :public_lighter, System.unique_integer([:positive])}
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, %{"height" => 123})
    end)

    exchange = Exchange.new!("lighter")

    assert {:ok, %{status: 200, body: %{"height" => 123}}} =
             Bourse.Lighter.public_get_currentheight(exchange, %{}, plug: {Req.Test, stub})

    conn = RequestCollector.one!(requests)
    assert Plug.Conn.get_req_header(conn, "authorization") == []
  end

  test "dispatch surfaces a sanitized signing failure as an authentication error" do
    exchange =
      Exchange.new!("lighter",
        credentials: Credentials.new!(api_key: "0", secret: "not-a-valid-key", uid: "1")
      )

    assert {:error, %Bourse.Error{type: :authentication_error} = error} =
             Bourse.Lighter.private_get_accountlimits(exchange, %{"account_index" => 1})

    assert error.message =~ "lighter_signing/invalid_credentials"
    refute error.message =~ "not-a-valid-key"
  end

  test "dispatch names the build command when the native helper is missing" do
    credentials = credentials(@private_key)
    exchange = Exchange.new!("lighter", credentials: credentials)

    exchange = %{
      exchange
      | signing_config: Map.put(exchange.signing_config, :helper_path, "/definitely/missing/lighter-helper")
    }

    assert {:error, %Bourse.Error{type: :authentication_error} = error} =
             Bourse.Lighter.private_get_accountlimits(exchange, %{"account_index" => 1})

    assert error.message =~ "mix ccxt.build_lighter_signer"
    refute error.message =~ @private_key
  end

  test "worker rejects requests before initialization and malformed executable arguments" do
    identity = :crypto.strong_rand_bytes(32)
    {:ok, pid} = Worker.start_link(identity)
    assert {:error, :not_initialized} = GenServer.call(pid, {:request, :auth_token, %{deadline: 0}, 100})
    GenServer.stop(pid)

    bad_args = %{helper_config("normal") | helper_args: ["bad\0argument"]}

    assert {:error, {:lighter_signing, :helper_unavailable}} =
             Lighter.sign(request(), credentials(@other_private_key), bad_args)
  end

  test "worker contains exit-status, linked-exit, and unrelated messages" do
    first = credentials(@private_key)
    second = credentials(@other_private_key)
    config = helper_config("normal")

    assert %SignedRequest{} = Lighter.sign(request(), first, config)
    assert {:ok, %{pid: first_pid}} = Lighter.helper_info(first, config)
    first_port = :sys.get_state(first_pid).port
    send(first_pid, :unrelated)
    assert Process.alive?(first_pid)
    first_monitor = Process.monitor(first_pid)
    send(first_pid, {first_port, {:exit_status, 99}})
    assert_receive {:DOWN, ^first_monitor, :process, ^first_pid, :normal}

    assert %SignedRequest{} = Lighter.sign(request(), second, config)
    assert {:ok, %{pid: second_pid}} = Lighter.helper_info(second, config)
    second_port = :sys.get_state(second_pid).port
    second_monitor = Process.monitor(second_pid)
    send(second_pid, {:EXIT, second_port, :simulated})
    assert_receive {:DOWN, ^second_monitor, :process, ^second_pid, :normal}
  end

  test "worker closes a newly-opened helper when initialization framing is invalid" do
    identity = :crypto.strong_rand_bytes(32)

    init_options = %{
      url: "",
      private_key: @private_key,
      chain_id: 304,
      api_key_index: 0,
      account_index: 1,
      helper_path: System.find_executable("elixir"),
      helper_args: [Path.expand("../../support/fixtures/lighter_helper.exs", __DIR__), "normal"]
    }

    assert {:error, :invalid_argument} = Worker.request(identity, init_options, :auth_token, %{deadline: 0})
    assert {:error, :not_running} = Worker.helper_info(identity)
  end

  test "worker sanitizes supervisor, status, timeout, linked-exit, and closed-port failures" do
    registered_identity = :crypto.strong_rand_bytes(32)
    {:ok, _value} = Registry.register(Bourse.Signing.Lighter.Registry, registered_identity, nil)
    assert {:error, :not_running} = Worker.helper_info(registered_identity)

    # A foreign owner of the registry name makes ensure_started/1 hand back that
    # process; the resulting exit is sanitized rather than propagated or leaked.
    assert {:error, :helper_terminated} = Worker.request(registered_identity, %{}, :auth_token, %{})
    Registry.unregister(Bourse.Signing.Lighter.Registry, registered_identity)

    timeout_identity = :crypto.strong_rand_bytes(32)

    assert {:error, :helper_terminated} =
             Worker.request(timeout_identity, worker_options("hang_on_auth"), :auth_token, %{deadline: 0}, 10)

    exit_identity = :crypto.strong_rand_bytes(32)
    {:ok, exit_pid} = Worker.start_link(exit_identity)
    assert :ok = GenServer.call(exit_pid, {:initialize, worker_options("hang_on_auth"), 2_000})
    exit_port = :sys.get_state(exit_pid).port

    # The request timeout is far longer than the test needs, so only the linked
    # exit below can satisfy the assertion — a timeout would be a false green.
    exit_task = Task.async(fn -> GenServer.call(exit_pid, {:request, :auth_token, %{deadline: 0}, 30_000}, 30_000) end)

    # Wait until the worker is actually blocked awaiting the helper's reply;
    # sending the exit first would kill it before the call arrives.
    assert_eventually(fn -> Process.info(exit_pid, :current_function) == {:current_function, {Worker, :transact, 5}} end)

    send(exit_pid, {:EXIT, exit_port, :simulated})
    assert {:error, :helper_terminated} = Task.await(exit_task)

    closed_identity = :crypto.strong_rand_bytes(32)
    {:ok, closed_pid} = Worker.start_link(closed_identity)

    closed_port =
      Port.open(
        {:spawn_executable, "elixir" |> System.find_executable() |> String.to_charlist()},
        [:exit_status, {:args, [~c"-e", ~c"IO.binread(:stdio, :eof)"]}]
      )

    Port.close(closed_port)
    :sys.replace_state(closed_pid, &%{&1 | port: closed_port})
    assert {:ok, %{os_pid: nil}} = GenServer.call(closed_pid, :helper_info)

    assert {:error, :helper_terminated} =
             GenServer.call(closed_pid, {:request, :auth_token, %{deadline: 0}, 100})
  end

  defp credentials(private_key) do
    Credentials.new!(api_key: "0", secret: private_key, uid: "1")
  end

  defp request(params \\ %{"account_index" => 1}) do
    %Request{method: :get, path: "/api/v1/accountLimits", body: nil, params: params}
  end

  defp cancel_order do
    %{market_index: 1, order_index: 2, skip_nonce: false, nonce: 3}
  end

  defp create_order do
    %{
      market_index: 1,
      client_order_index: 2,
      base_amount: 3,
      price: 4,
      is_ask: false,
      order_type: 0,
      time_in_force: 1,
      reduce_only: false,
      trigger_price: 0,
      order_expiry: -1,
      integrator_account_index: 0,
      integrator_taker_fee: 0,
      integrator_maker_fee: 0,
      self_trade_behavior: 0,
      self_trade_equality: 0,
      skip_nonce: false,
      nonce: 3
    }
  end

  defp helper_config(mode) do
    %{
      base_url: "https://testnet.zklighter.elliot.ai",
      helper_path: System.find_executable("elixir"),
      helper_args: [Path.expand("../../support/fixtures/lighter_helper.exs", __DIR__), mode]
    }
  end

  defp worker_options(mode) do
    config = helper_config(mode)

    %{
      url: config.base_url,
      private_key: @private_key,
      chain_id: 304,
      api_key_index: 0,
      account_index: 1,
      helper_path: config.helper_path,
      helper_args: config.helper_args
    }
  end

  defp assert_eventually(fun, attempts \\ 20)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      receive do
      after
        10 -> assert_eventually(fun, attempts - 1)
      end
    end
  end
end
