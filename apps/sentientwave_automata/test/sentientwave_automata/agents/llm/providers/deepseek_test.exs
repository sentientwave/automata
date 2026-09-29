defmodule SentientwaveAutomata.Agents.LLM.Providers.DeepSeekTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Agents.LLM.Providers.DeepSeek

  test "returns missing_api_key when the DeepSeek token is missing" do
    assert {:error, :missing_api_key} =
             DeepSeek.complete(
               [%{"role" => "user", "content" => "Hello DeepSeek"}],
               api_key: ""
             )
  end

  test "sends OpenAI-compatible chat completion requests to DeepSeek" do
    test_pid = self()

    {base_url, _server_pid} =
      start_stub_server(test_pid, fn _request ->
        %{
          status: 200,
          body: %{
            "id" => "chatcmpl_test",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{"role" => "assistant", "content" => "Hello from DeepSeek"}
              }
            ]
          }
        }
      end)

    assert {:ok, "Hello from DeepSeek"} =
             DeepSeek.complete(
               [%{"role" => "user", "content" => "Hello DeepSeek"}],
               api_key: "sk_test_key",
               base_url: base_url,
               model: "deepseek-v4-pro",
               timeout_seconds: 5
             )

    assert_receive {:deepseek_request, request}, 5_000

    {headers, body} = split_request(request)
    payload = Jason.decode!(body)

    assert headers =~ "POST /v1/chat/completions HTTP/1.1"
    assert String.downcase(headers) =~ "authorization: bearer sk_test_key"
    assert payload["model"] == "deepseek-v4-pro"
    assert payload["temperature"] == 0.2
  end

  test "returns structured http errors from DeepSeek" do
    test_pid = self()

    {base_url, _server_pid} =
      start_stub_server(test_pid, fn _request ->
        %{status: 401, body: %{"error" => %{"message" => "invalid api key"}}}
      end)

    assert {:error, :http_error} =
             DeepSeek.complete(
               [%{"role" => "user", "content" => "Hello DeepSeek"}],
               api_key: "sk_test_key",
               base_url: base_url,
               model: "deepseek-v4-pro",
               timeout_seconds: 5
             )

    assert_receive {:deepseek_request, _request}, 5_000
  end

  defp start_stub_server(test_pid, responder) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    server_pid =
      start_supervised!({Task, fn -> serve_once(listen_socket, test_pid, responder) end})

    {"http://127.0.0.1:#{port}/v1", server_pid}
  end

  defp serve_once(listen_socket, test_pid, responder) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)
    {:ok, request} = read_request(socket, "")
    send(test_pid, {:deepseek_request, request})

    %{status: status, body: body} = responder.(request)
    response_body = Jason.encode!(body)

    response =
      [
        "HTTP/1.1 ",
        Integer.to_string(status),
        " ",
        reason_phrase(status),
        "\r\ncontent-type: application/json\r\ncontent-length: ",
        Integer.to_string(byte_size(response_body)),
        "\r\nconnection: close\r\n\r\n",
        response_body
      ]
      |> IO.iodata_to_binary()

    :ok = :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
    :gen_tcp.close(listen_socket)
  end

  defp read_request(socket, buffer) do
    case complete_request(buffer) do
      {:ok, request} ->
        {:ok, request}

      :more ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_request(socket, buffer <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp complete_request(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {header_end, 4} ->
        headers = binary_part(buffer, 0, header_end)
        body_offset = header_end + 4
        body_size = byte_size(buffer) - body_offset
        body = binary_part(buffer, body_offset, body_size)
        content_length = content_length(headers)

        if byte_size(body) >= content_length do
          {:ok, headers <> "\r\n\r\n" <> binary_part(body, 0, content_length)}
        else
          :more
        end

      :nomatch ->
        :more
    end
  end

  defp content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(name) == "content-length" do
            value |> String.trim() |> String.to_integer()
          end

        _ ->
          nil
      end
    end)
  end

  defp split_request(request) do
    [headers, body] = String.split(request, "\r\n\r\n", parts: 2)
    {headers, body}
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(401), do: "Unauthorized"
  defp reason_phrase(_), do: "Error"
end
