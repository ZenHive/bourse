defmodule Bourse.Signing.LighterFailureTest do
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Signing.Lighter
  alias Bourse.Signing.Lighter.Worker
  alias Bourse.Signing.Request

  @secret String.duplicate("01", 40)
  @base_url "https://testnet.zklighter.elliot.ai"

  test "invalid credentials and configuration fail before a helper starts" do
    request = %Request{method: :get, path: "/account", params: %{}, body: nil}

    for {credentials, config} <- [
          {credentials(secret: "short"), config()},
          {credentials(api_key: "not-an-integer"), config()},
          {credentials(uid: "0"), config()},
          {credentials(), %{config() | base_url: ""}},
          {credentials(), %{config() | helper_path: ""}},
          {credentials(), Map.put(config(), :chain_id, "bad")}
        ] do
      assert {:error, {:lighter_signing, reason}} = Lighter.sign(request, credentials, config)
      assert reason in [:invalid_credentials, :invalid_configuration]
    end
  end

  test "transaction requests validate operation and nested params" do
    request = %Request{
      method: :post,
      path: "/transaction",
      body: nil,
      params: %{"__bourse_lighter_transaction_operation" => "unknown", "__bourse_lighter_transaction_params" => %{}}
    }

    assert {:error, {:lighter_signing, :invalid_configuration}} = Lighter.sign(request, credentials(), config())

    request = %{request | params: %{"__bourse_lighter_transaction_operation" => "create_order"}}
    assert {:error, {:lighter_signing, :invalid_configuration}} = Lighter.sign(request, credentials(), config())
  end

  test "missing helper is a sanitized error across public operations" do
    missing = Path.join(System.tmp_dir!(), "missing-lighter-helper-#{System.unique_integer([:positive])}")
    config = %{config() | helper_path: missing}
    credentials = credentials()

    assert {:error, {:lighter_signing, :helper_unavailable}} =
             Lighter.sign(%Request{method: :get, path: "/account", params: %{"accountIndex" => "1"}}, credentials, config)

    assert {:error, {:lighter_signing, :helper_unavailable}} =
             Lighter.sign_transaction(:auth_token, %{deadline: 1}, credentials, config)

    assert {:error, :not_running} = Lighter.helper_info(credentials, config)
    assert :ok = Lighter.terminate_helper(credentials, config)
  end

  test "worker callbacks cover uninitialized, metadata, messages, and redaction" do
    identity = :crypto.strong_rand_bytes(32)
    assert {:ok, state} = Worker.init(identity)

    assert {:reply, {:error, :not_initialized}, ^state} =
             Worker.handle_call({:request, :auth_token, %{}, 1}, self(), state)

    assert {:reply, {:ok, %{pid: pid, os_pid: nil}}, ^state} = Worker.handle_call(:helper_info, self(), state)
    assert pid == self()
    assert {:noreply, ^state} = Worker.handle_info(:unknown, state)
    assert :ok = Worker.terminate(:normal, state)
    assert Worker.format_status(:anything) == %{state: :redacted}
  end

  test "worker start, lookup, duplicate start, and termination are observable" do
    identity = :crypto.strong_rand_bytes(32)
    assert {:ok, pid} = Worker.start_link(identity)
    assert {:ok, %{pid: ^pid, os_pid: nil}} = Worker.helper_info(identity)
    assert {:error, {:already_started, ^pid}} = Worker.start_link(identity)
    assert :ok = Worker.terminate(identity)
    GenServer.stop(pid)
    assert {:error, :not_running} = Worker.helper_info(identity)
  end

  test "worker handles an already-open port and sanitizes protocol failures" do
    port = Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary, {:packet, 2}, :use_stdio, :exit_status])
    state = %{identity: <<1>>, port: port, request_id: 0}

    assert {:reply, :ok, ^state} = Worker.handle_call({:initialize, %{}, 10}, self(), state)
    assert {:reply, {:ok, %{pid: pid, os_pid: os_pid}}, ^state} = Worker.handle_call(:helper_info, self(), state)
    assert pid == self()
    assert is_integer(os_pid)

    assert {:reply, {:error, :protocol_error}, %{request_id: 1}} =
             Worker.handle_call({:request, :auth_token, %{deadline: 1}, 100}, self(), state)

    assert {:stop, :normal, ^state} = Worker.handle_info({port, {:exit_status, 1}}, state)
    assert {:stop, :normal, ^state} = Worker.handle_info({:EXIT, port, :normal}, state)
    assert :ok = Worker.terminate(:normal, state)
  end

  test "worker rejects relative and absent executables without leaking init options" do
    identity = :crypto.strong_rand_bytes(32)

    init = %{
      url: @base_url,
      private_key: @secret,
      chain_id: 304,
      api_key_index: 0,
      account_index: 1,
      helper_path: "relative/helper",
      helper_args: []
    }

    assert {:error, :helper_unavailable} = Worker.request(identity, init, :auth_token, %{deadline: 1}, 10)
    assert {:error, :not_running} = Worker.helper_info(identity)
  end

  test "worker contains initialization protocol errors and invalid requests" do
    init = init_options("/bin/cat")

    assert {:error, :protocol_error} =
             Worker.request(:crypto.strong_rand_bytes(32), init, :auth_token, %{deadline: 1}, 100)

    helper = protocol_helper!()

    assert {:error, :invalid_argument} =
             Worker.request(:crypto.strong_rand_bytes(32), init_options(helper), :unsupported, %{}, 100)
  end

  test "worker contains helper exit and timeout after successful initialization" do
    helper = protocol_helper!()

    assert {:error, :helper_terminated} =
             Worker.request(
               :crypto.strong_rand_bytes(32),
               init_options(helper, ["exit"]),
               :auth_token,
               %{deadline: 1},
               100
             )

    assert {:error, :helper_terminated} =
             Worker.request(:crypto.strong_rand_bytes(32), init_options(helper, ["hang"]), :auth_token, %{deadline: 1}, 5)

    assert {:error, :helper_unavailable} =
             Worker.request(:crypto.strong_rand_bytes(32), init_options("relative"), :auth_token, %{}, :infinity)
  end

  test "worker catches self-call lookup and reports a closed port without an OS pid" do
    identity = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = Registry.register(Bourse.Signing.Lighter.Registry, identity, nil)
    assert {:error, :not_running} = Worker.helper_info(identity)
    Registry.unregister(Bourse.Signing.Lighter.Registry, identity)

    port = Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary])
    Port.close(port)
    state = %{identity: identity, port: port, request_id: 0}
    assert {:reply, {:ok, %{os_pid: nil}}, ^state} = Worker.handle_call(:helper_info, self(), state)

    assert {:stop, :normal, {:error, :helper_terminated}, ^state} =
             Worker.handle_call({:request, :auth_token, %{deadline: 1}, 10}, self(), state)
  end

  test "worker catches invalid call timeouts and executable-format errors" do
    identity = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = Registry.register(Bourse.Signing.Lighter.Registry, identity, nil)

    assert {:error, :helper_terminated} =
             Worker.request(identity, init_options("relative"), :auth_token, %{}, 10)

    Registry.unregister(Bourse.Signing.Lighter.Registry, identity)

    path = Path.join(System.tmp_dir!(), "bourse-invalid-executable-#{System.unique_integer([:positive])}")
    File.write!(path, "not an executable image")
    File.chmod!(path, 0o700)

    assert {:error, :helper_terminated} =
             Worker.request(:crypto.strong_rand_bytes(32), init_options(path), :auth_token, %{}, 10)
  end

  defp credentials(overrides \\ []) do
    Credentials.new!(
      api_key: Keyword.get(overrides, :api_key, "0"),
      secret: Keyword.get(overrides, :secret, @secret),
      uid: Keyword.get(overrides, :uid, "1")
    )
  end

  defp config do
    %{base_url: @base_url, helper_path: "/definitely/missing/lighter-helper", testnet: true}
  end

  defp init_options(helper_path, helper_args \\ []) do
    %{
      url: @base_url,
      private_key: @secret,
      chain_id: 304,
      api_key_index: 0,
      account_index: 1,
      helper_path: helper_path,
      helper_args: helper_args
    }
  end

  defp protocol_helper! do
    path = Path.join(System.tmp_dir!(), "bourse-lighter-protocol-helper-#{System.unique_integer([:positive])}")

    File.write!(path, """
    #!/usr/bin/python3
    import signal, struct, sys, time
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    def read_frame():
        header = sys.stdin.buffer.read(2)
        if len(header) != 2: return None
        return sys.stdin.buffer.read(struct.unpack('>H', header)[0])
    def write_frame(payload):
        try:
            sys.stdout.buffer.write(struct.pack('>H', len(payload)) + payload)
            sys.stdout.buffer.flush()
        except BrokenPipeError:
            sys.exit(0)
    init = read_frame()
    if init:
        write_frame(bytes([1, 1]) + init[2:6] + bytes([0, 0]))
    request = read_frame()
    mode = sys.argv[1] if len(sys.argv) > 1 else 'reply'
    if mode == 'exit': sys.exit(1)
    if mode == 'hang': time.sleep(2)
    if request: write_frame(bytes([1, request[1]]) + request[2:6] + bytes([1, 0, 1]))
    """)

    File.chmod!(path, 0o700)
    path
  end
end
