defmodule Bourse.Signing.LighterNativeTest do
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Signing.Lighter
  alias Bourse.Signing.Lighter.Protocol
  alias Bourse.Signing.Request
  alias Bourse.Signing.SignedRequest

  @moduletag :native
  @private_key "07000000000000000300000000000000000000000000000000000000000000000000000000000000"
  @base_url "https://testnet.zklighter.elliot.ai"
  @port_timeout_ms 5_000
  @empty_memo String.duplicate("00", 32)

  setup do
    credentials = Credentials.new!(api_key: "0", secret: @private_key, uid: "1")
    config = %{base_url: @base_url, helper_path: helper_path()}

    on_exit(fn -> Lighter.terminate_helper(credentials, config) end)
    {:ok, credentials: credentials, config: config}
  end

  test "official C ABI creates auth tokens and signed orders", %{credentials: credentials, config: config} do
    request = %Request{
      method: :get,
      path: "/api/v1/accountLimits",
      body: nil,
      params: %{"account_index" => 1, "auth_deadline" => 1_800_000_000}
    }

    assert %SignedRequest{headers: [{"Authorization", token}]} =
             Lighter.sign(request, credentials, config)

    assert token =~ ~r/^1800000000:1:0:[0-9a-f]{160}$/

    assert {:ok, %{tx_type: 14, tx_info: tx_info, tx_hash: tx_hash, message_to_sign: message}} =
             Lighter.sign_transaction(:create_order, create_order(), credentials, config)

    assert {:ok, %{"Sig" => signature}} = Jason.decode(tx_info)
    assert {:ok, signature_bytes} = Base.decode64(signature)
    assert byte_size(signature_bytes) == 80
    assert tx_hash =~ ~r/^[0-9a-f]{80}$/
    assert message == ""
  end

  test "crashing the official helper cannot terminate the VM and a new helper restarts", %{
    credentials: credentials,
    config: config
  } do
    assert %SignedRequest{} = Lighter.sign(request(), credentials, config)
    assert {:ok, %{pid: first_pid, os_pid: os_pid}} = Lighter.helper_info(credentials, config)

    monitor = Process.monitor(first_pid)
    kill_process!(os_pid)
    assert_receive {:DOWN, ^monitor, :process, ^first_pid, :normal}
    assert Process.alive?(self())

    assert %SignedRequest{} = Lighter.sign(request(), credentials, config)
    assert {:ok, %{pid: second_pid}} = Lighter.helper_info(credentials, config)
    refute first_pid == second_pid
  end

  test "C helper parses and frames every supported operation" do
    port = open_helper()
    initialize_port!(port, 100)

    operation_cases()
    |> Enum.with_index(101)
    |> Enum.each(fn {{operation, params}, request_id} ->
      assert {:ok, request} = Protocol.encode_request(request_id, operation, params)
      response = exchange_frame!(port, request)

      case Protocol.decode_response(response, operation, request_id) do
        {:ok, token} when operation == :auth_token ->
          assert token =~ ~r/^1800000000:1:0:[0-9a-f]{160}$/

        {:ok, %{tx_type: tx_type, tx_info: tx_info, tx_hash: tx_hash, message_to_sign: message}} ->
          assert tx_type > 0
          assert {:ok, _decoded} = Jason.decode(tx_info)
          assert is_binary(tx_hash)
          assert is_binary(message)

        other ->
          flunk("#{operation} returned #{inspect(other)}")
      end
    end)
  end

  test "C helper rejects malformed frames and parser boundary violations" do
    failed_init_port = open_helper()
    assert {:ok, failed_init} = Protocol.encode_init(199, @base_url, "not-a-key", 304, 0, 1)

    assert {:error, :client_initialization_failed} =
             failed_init_port |> exchange_frame!(failed_init) |> Protocol.decode_response(:init, 199)

    port = open_helper()

    assert {:ok, auth_request} = Protocol.encode_request(200, :auth_token, %{deadline: 1_800_000_000})

    assert {:error, :not_initialized} =
             port |> exchange_frame!(auth_request) |> Protocol.decode_response(:auth_token, 200)

    assert <<1, 0, 0::32, 1, 0, 1>> = exchange_frame!(port, <<2, 2, 201::32, 0::signed-64>>)
    assert <<1, 0, 0::32, 1, 0, 1>> = exchange_frame!(port, <<1, 2, 0>>)

    invalid_init = <<1, 1, 202::32, 0::16, 0::16, 304::32, 0, 1::signed-64>>

    assert {:error, :invalid_argument} =
             port |> exchange_frame!(invalid_init) |> Protocol.decode_response(:init, 202)

    initialize_port!(port, 203)

    assert {:ok, init_request} = Protocol.encode_init(204, @base_url, @private_key, 304, 0, 1)

    assert {:error, :already_initialized} =
             port |> exchange_frame!(init_request) |> Protocol.decode_response(:init, 204)

    assert <<1, 99, 205::32, 1, 0, 1>> = exchange_frame!(port, <<1, 99, 205::32>>)

    assert {:error, :invalid_argument} =
             port |> exchange_frame!(<<1, 3, 206::32>>) |> Protocol.decode_response(:create_order, 206)

    assert {:error, :invalid_argument} =
             port |> exchange_frame!(<<1, 5, 207::32>>) |> Protocol.decode_response(:cancel_all_orders, 207)

    operation_cases()
    |> Enum.with_index(208)
    |> Enum.each(fn {{operation, params}, request_id} ->
      assert {:ok, request} = Protocol.encode_request(request_id, operation, params)
      truncated = binary_part(request, 0, byte_size(request) - 1)

      assert {:error, :invalid_argument} =
               port |> exchange_frame!(truncated) |> Protocol.decode_response(operation, request_id)

      assert {:error, :invalid_argument} =
               port |> exchange_frame!(request <> <<0>>) |> Protocol.decode_response(operation, request_id)
    end)

    invalid_parser_frames()
    |> Enum.with_index(300)
    |> Enum.each(fn {{operation, operation_code, payload}, request_id} ->
      request = <<1, operation_code, request_id::32, payload::binary>>

      assert {:error, :invalid_argument} =
               port |> exchange_frame!(request) |> Protocol.decode_response(operation, request_id)
    end)
  end

  defp request do
    %Request{
      method: :get,
      path: "/api/v1/accountLimits",
      body: nil,
      params: %{"account_index" => 1, "auth_deadline" => 1_800_000_000}
    }
  end

  defp create_order do
    %{
      market_index: 1,
      client_order_index: 123,
      base_amount: 1000,
      price: 200_000,
      is_ask: false,
      order_type: 0,
      time_in_force: 0,
      reduce_only: false,
      trigger_price: 0,
      order_expiry: 0,
      integrator_account_index: 0,
      integrator_taker_fee: 0,
      integrator_maker_fee: 0,
      self_trade_behavior: 0,
      self_trade_equality: 0,
      skip_nonce: false,
      nonce: 7
    }
  end

  defp operation_cases do
    [
      {:auth_token, %{deadline: 1_800_000_000}},
      {:create_order, create_order()},
      {:cancel_order, %{market_index: 1, order_index: 2, skip_nonce: false, nonce: 3}},
      {:cancel_all_orders, %{time_in_force: 0, time: 0, market_index: 1, skip_nonce: false, nonce: 4}},
      {:modify_order,
       %{
         market_index: 1,
         index: 2,
         base_amount: 3,
         price: 4,
         trigger_price: 0,
         integrator_account_index: 5,
         integrator_taker_fee: 6,
         integrator_maker_fee: 7,
         self_trade_behavior: 0,
         self_trade_equality: 0,
         skip_nonce: false,
         nonce: 8
       }},
      {:update_leverage, %{market_index: 1, initial_margin_fraction: 100, margin_mode: 0, skip_nonce: false, nonce: 9}},
      {:update_margin, %{market_index: 1, usdc_amount: -10, direction: 1, skip_nonce: false, nonce: 10}},
      {:transfer,
       %{
         to_account_index: 1,
         asset_index: 2,
         from_route: 0,
         to_route: 1,
         amount: 100_000_000,
         usdc_fee: 3_000_000,
         memo: @empty_memo,
         skip_nonce: false,
         nonce: 11
       }}
    ]
  end

  defp invalid_parser_frames do
    [
      {:auth_token, 2, <<-1::signed-64>>},
      {:create_order, 3,
       <<0x8000::16, 0::signed-64, 0::signed-64, 0::32, 0, 0, 0, 0, 0::32>> <>
         <<0::signed-64, 0::signed-64, 0::32, 0::32, 0, 0, 0, 0::signed-64>>},
      {:cancel_order, 4, <<0x8000::16, 0::signed-64, 0, 0::signed-64>>},
      {:cancel_all_orders, 5, <<0, 0::signed-64, 0x8000::16, 0, 0::signed-64>>},
      {:modify_order, 6,
       <<0x8000::16, 0::signed-64, 0::signed-64, 0::signed-64, 0::signed-64, 0::signed-64, 0::32, 0::32, 0, 0, 0,
         0::signed-64>>},
      {:update_leverage, 7, <<0::16, 0x10000::32, 0, 0, 0::signed-64>>},
      {:update_margin, 8, <<0::16, 0::signed-64, 0, 2, 0::signed-64>>},
      {:transfer, 9, invalid_transfer_frame()}
    ]
  end

  defp invalid_transfer_frame do
    fields = <<1::signed-64, 2::16, 2, 1, 100_000_000::signed-64, 3_000_000::signed-64>>
    fields <> @empty_memo <> <<0, 11::signed-64>>
  end

  defp initialize_port!(port, request_id) do
    assert {:ok, request} = Protocol.encode_init(request_id, @base_url, @private_key, 304, 0, 1)
    assert :ok = port |> exchange_frame!(request) |> Protocol.decode_response(:init, request_id)
  end

  defp open_helper do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(helper_path())},
        [:binary, {:packet, 2}, :use_stdio, :exit_status, :hide]
      )

    on_exit(fn -> close_port(port) end)
    port
  end

  defp exchange_frame!(port, request) do
    assert Port.command(port, request)

    receive do
      {^port, {:data, response}} -> response
      {^port, {:exit_status, status}} -> flunk("native helper exited with status #{status}")
    after
      @port_timeout_ms -> flunk("native helper did not answer within #{@port_timeout_ms} ms")
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp helper_path do
    Application.app_dir(:bourse, [
      "priv",
      "native",
      "lighter_signer",
      platform_target(),
      executable_name()
    ])
  end

  defp platform_target do
    os = if match?({:win32, _}, :os.type()), do: "windows", else: unix_os()

    architecture =
      if String.contains?(List.to_string(:erlang.system_info(:system_architecture)), ["aarch64", "arm64"]),
        do: "arm64",
        else: "amd64"

    "#{os}-#{architecture}"
  end

  defp unix_os do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, _name} -> "linux"
    end
  end

  defp executable_name do
    if match?({:win32, _}, :os.type()), do: "bourse_lighter_signer.exe", else: "bourse_lighter_signer"
  end

  defp kill_process!(os_pid) do
    {command, args} =
      if match?({:win32, _}, :os.type()) do
        {"taskkill", ["/PID", Integer.to_string(os_pid), "/F"]}
      else
        {"kill", ["-KILL", Integer.to_string(os_pid)]}
      end

    assert {_output, 0} = System.cmd(command, args, stderr_to_stdout: true)
  end
end
