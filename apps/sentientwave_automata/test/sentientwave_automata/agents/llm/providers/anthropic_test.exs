defmodule SentientwaveAutomata.Agents.LLM.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Agents.LLM.Providers.Anthropic

  test "returns missing_api_key when the Anthropic token is missing" do
    assert {:error, :missing_api_key} =
             Anthropic.complete(
               [%{"role" => "user", "content" => "Hello Claude"}],
               api_key: ""
             )
  end

  test "translates messages into Anthropic format and extracts text content" do
    test_pid = self()

    {base_url, _server_pid} =
      start_stub_server(test_pid, fn _request ->
        %{
          status: 200,
          body: %{
            "id" => "msg_test",
            "type" => "message",
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "Hello from Claude"}
            ]
          }
        }
      end)

    assert {:ok, "Hello from Claude"} =
             Anthropic.complete(
               [
                 %{"role" => "system", "content" => "Core system instruction."},
                 %{"role" => "system", "content" => "Skill instruction."},
                 %{"role" => "user", "content" => "First user turn"},
                 %{"role" => "assistant", "content" => "Assistant context"},
                 %{"role" => "user", "content" => "Second user turn"}
               ],
               api_key: "sk-ant-test",
               base_url: base_url,
               model: "claude-3-5-haiku-latest",
               max_tokens: 512,
               timeout_seconds: 5
             )

    assert_receive {:anthropic_request, request}, 5_000

    {headers, body} = split_request(request)
    payload = Jason.decode!(body)

    assert headers =~ "POST /v1/messages HTTP/1.1"
    assert String.downcase(headers) =~ "x-api-key: sk-ant-test"
    assert String.downcase(headers) =~ "anthropic-version: 2023-06-01"
    assert payload["model"] == "claude-3-5-haiku-latest"
    assert payload["max_tokens"] == 512
    assert payload["system"] == "Core system instruction.\n\nSkill instruction."

    assert payload["messages"] == [
             %{"role" => "user", "content" => "First user turn"},
             %{"role" => "assistant", "content" => "Assistant context"},
             %{"role" => "user", "content" => "Second user turn"}
           ]
  end

  test "returns structured http errors from Anthropic" do
    test_pid = self()

    {base_url, _server_pid} =
      start_stub_server(test_pid, fn _request ->
        %{
          status: 401,
          body: %{
            "type" => "error",
            "error" => %{
              "type" => "authentication_error",
              "message" => "invalid x-api-key"
            }
          }
        }
      end)

    assert {:error,
            {:http_error, 401,
             %{
               "type" => "error",
               "error" => %{
                 "type" => "authentication_error",
                 "message" => "invalid x-api-key"
               }
             }}} =
             Anthropic.complete(
               [%{"role" => "user", "content" => "Hello Claude"}],
               api_key: "sk-ant-test",
               base_url: base_url,
               model: "claude-3-5-haiku-latest",
               timeout_seconds: 5
             )

    assert_receive {:anthropic_request, _request}, 5_000
  end

  defp start_stub_server(test_pid, responder) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    server_pid =
      start_supervised!(
        {Task,
         fn ->
           serve_once(listen_socket, test_pid, responder)
         end}
      )

    {"http://127.0.0.1:#{port}", server_pid}
  end

  defp serve_once(listen_socket, test_pid, responder) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)
    {:ok, request} = read_request(socket, "")
    send(test_pid, {:anthropic_request, request})

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
        [name, value] when String.downcase(name) == "content-length" ->
          value
          |> String.trim()
          |> String.to_integer()

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
