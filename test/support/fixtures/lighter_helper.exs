defmodule Bourse.Test.LighterHelper do
  @moduledoc false
  @version 1
  @testnet_chain_id 300

  @spec run(String.t()) :: :ok
  def run(mode) do
    install_stdout_filter()
    run_mode(mode)
  end

  defp run_mode("write_error"), do: write_frame(<<0>>, error_io_device(:enospc))
  defp run_mode("write_terminated"), do: write_frame(<<0>>, error_io_device(:terminated))
  defp run_mode(mode), do: loop(mode, false)

  defp loop(mode, initialized) do
    case read_stdio(2) do
      <<length::16>> ->
        frame = read_stdio(length)
        process_frame(mode, initialized, frame)

      _eof ->
        :ok
    end
  end

  defp process_frame(mode, initialized, <<@version, operation, request_id::32, payload::binary>>) do
    loop(mode, handle_operation(mode, initialized, operation, request_id, payload))
  end

  defp process_frame(_mode, _initialized, _frame), do: System.halt(74)

  # Each clause performs its side effect and returns the next `initialized` flag.
  defp handle_operation(mode, false, 1, request_id, payload) do
    init(mode, request_id, payload)
    true
  end

  defp handle_operation(_mode, true, 1, request_id, _payload) do
    error(1, request_id, 3)
    true
  end

  defp handle_operation(_mode, false, operation, request_id, _payload) do
    error(operation, request_id, 2)
    false
  end

  defp handle_operation("crash_on_auth", true, 2, _request_id, _payload), do: System.halt(73)

  # Never answers the request, but still exits once the port closes stdin, so a
  # hung helper is never orphaned holding the test runner's pipes open.
  defp handle_operation("hang_on_auth", true, 2, _request_id, _payload) do
    IO.binread(:stdio, :eof)
    System.halt(75)
  end

  defp handle_operation("bad_response", true, _operation, _request_id, _payload) do
    write_frame(<<0>>)
    true
  end

  defp handle_operation(_mode, true, 2, request_id, payload) do
    auth_token(request_id, payload)
    true
  end

  defp handle_operation(_mode, true, operation, request_id, _payload) when operation in 3..8 do
    signed_transaction(operation, request_id)
    true
  end

  defp handle_operation(_mode, true, operation, request_id, _payload) do
    error(operation, request_id, 1)
    true
  end

  defp init(mode, request_id, payload) do
    with <<url_length::16, rest::binary>> <- payload,
         <<_url::binary-size(^url_length), key_length::16, rest::binary>> <- rest,
         <<private_key::binary-size(^key_length), chain_id::32, _api_key_index, _account_index::signed-64>> <- rest,
         false <- leaked?(private_key),
         true <- valid_chain_id?(mode, chain_id) do
      if mode == "init_error", do: error(1, request_id, 5), else: success(1, request_id)
    else
      _failure -> error(1, request_id, 4)
    end
  end

  defp valid_chain_id?("expect_testnet_chain", chain_id), do: chain_id == @testnet_chain_id
  defp valid_chain_id?(_mode, _chain_id), do: true

  defp leaked?(private_key) do
    Enum.any?(System.argv(), &String.contains?(&1, private_key)) or
      Enum.any?(System.get_env(), fn {name, value} ->
        String.contains?(name, private_key) or String.contains?(value, private_key)
      end)
  end

  defp auth_token(request_id, <<deadline::signed-64>>) do
    token = "#{deadline}:1:0:fake-signature"
    response(2, request_id, <<byte_size(token)::16, token::binary>>)
  end

  defp auth_token(request_id, _payload), do: error(2, request_id, 4)

  defp signed_transaction(operation, request_id) do
    tx_info = ~s({"signature":"fake-signature"})
    tx_hash = "fake-hash"
    message = "fake-message"

    payload =
      <<14, byte_size(tx_info)::32, tx_info::binary, byte_size(tx_hash)::32, tx_hash::binary, byte_size(message)::32,
        message::binary>>

    response(operation, request_id, payload)
  end

  defp success(operation, request_id), do: response(operation, request_id, <<>>)

  defp response(operation, request_id, payload) do
    write_frame(<<@version, operation, request_id::32, 0, 0, payload::binary>>)
  end

  defp error(operation, request_id, code) do
    write_frame(<<@version, operation, request_id::32, 1, 0, code>>)
  end

  defp write_frame(frame), do: write_frame(frame, :stdio)

  defp write_frame(frame, device) do
    write_guarded(device, <<byte_size(frame)::16, frame::binary>>)
  end

  # user_drv reports a closed stdout as :epipe, then IO raises :terminated. That
  # teardown is an ordinary end-of-stream; every other write failure stays loud.
  defp write_guarded(device, data) do
    IO.binwrite(device, data)
  catch
    :error, :terminated -> :ok
  end

  defp read_stdio(length) do
    IO.binread(:stdio, length)
  catch
    :error, :terminated -> :eof
  end

  defp install_stdout_filter do
    :ok = :logger.add_primary_filter(__MODULE__, {&filter_closed_stdout/2, nil})
  end

  defp filter_closed_stdout(%{msg: {~c"Writer crashed (~p)", [:epipe]}}, _config), do: :stop

  defp filter_closed_stdout(_event, _config), do: :ignore

  defp error_io_device(reason) do
    spawn(fn ->
      receive do
        {:io_request, from, reply_as, _request} ->
          send(from, {:io_reply, reply_as, {:error, reason}})
      end
    end)
  end
end

Bourse.Test.LighterHelper.run(List.first(System.argv()) || "normal")
