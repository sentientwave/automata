defmodule SentientwaveAutomata.Agents.LLM.Providers.GeminiTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Agents.LLM.Providers.Gemini

  test "returns missing_api_key when the Gemini token is missing" do
    assert {:error, :missing_api_key} =
             Gemini.complete(
               [%{"role" => "user", "content" => "Hello Gemini"}],
               api_key: ""
             )
  end

  test "translates messages into Gemini format and extracts text content" do
    test_pid = self()

    {base_url, _server_pid} =
      start_stub_server(test_pid, fn _request ->
        %{
          status: 200,
          body: %{
            "candidates" => [
              %{
                "content" => %{
                  "parts" => [
                    %{"text" => "Hello from Gemini"}
                  ]
                }
              }
            ]
          }
        }
      end)

    assert {:ok, "Hello from Gemini"} =
             Gemini.complete(
               [
                 %{"role" => "system", "content" => "Core system instruction."},
                 %{"role" => "system", "content" => "Skill instruction."},
                 %{"role" => "user", "content" => "First user turn"},
                 %{"role" => "assistant", "content" => "Assistant context"},
                 %{"role" => "user", "content" => "Second user turn"}
               ],
               api_key: "gemini_test_key",
               base_url: base_url,
               model: "gemini-3.1-pro-preview",
               max_tokens: 512,
               timeout_seconds: 5
             )

    assert_receive {:gemini_request, request}, 5_000

    {headers, body} = split_request(request)
    payload = Jason.decode!(body)

    assert headers =~ "POST /v1beta/models/gemini-3.1-pro-preview:generateContent HTTP/1.1"
    assert String.downcase(headers) =~ "x-goog-api-key: gemini_test_key"

    assert payload["system_instruction"] == %{
             "parts" => [%{"text" => "Core system instruction.\n\nSkill instruction."}]
           }

    assert payload["generationConfig"] == %{
             "temperature" => 0.2,
             "maxOutputTokens" => 512
           }

    assert payload["contents"] == [
             %{"role" => "user", "parts" => [%{"text" => "First user turn"}]},
             %{"role" => "model", "parts" => [%{"text" => "Assistant context"}]},
             %{"role" => "user", "parts" => [%{"text" => "Second user turn"}]}
           ]
  end

  test "returns structured http errors from Gemini" do
    test_pid = self()

    {base_url, _server_pid} =
      start_stub_server(test_pid, fn _request ->
        %{
          status: 400,
          body: %{
            "error" => %{
              "code" => 400,
              "message" => "API key not valid. Please pass a valid API key.",
              "status" => "INVALID_ARGUMENT"
            }
          }
        }
      end)

    assert {:error,
            {:http_error, 400,
             %{
               "error" => %{
                 "code" => 400,
                 "message" => "API key not valid. Please pass a valid API key.",
                 "status" => "INVALID_ARGUMENT"
               }
             }}} =
             Gemini.complete(
               [%{"role" => "user", "content" => "Hello Gemini"}],
               api_key: "gemini_test_key",
               base_url: base_url,
               model: "gemini-3.1-pro-preview",
               timeout_seconds: 5
             )

    assert_receive {:gemini_request, _request}, 5_000
  end

  test "returns blocked_prompt when Gemini rejects the prompt" do
    test_pid = self()

    {base_url, _server_pid} =
      start_stub_server(test_pid, fn _request ->
        %{
          status: 200,
          body: %{
            "promptFeedback" => %{
              "blockReason" => "SAFETY"
            }
          }
        }
      end)

    assert {:error,
            {:blocked_prompt,
             %{
               "promptFeedback" => %{
                 "blockReason" => "SAFETY"
               }
             }}} =
             Gemini.complete(
               [%{"role" => "user", "content" => "Hello Gemini"}],
               api_key: "gemini_test_key",
               base_url: base_url,
               model: "gemini-3.1-pro-preview",
               timeout_seconds: 5
             )

    assert_receive {:gemini_request, _request}, 5_000
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
    send(test_pid, {:gemini_request, request})

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
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(_), do: "Error"
end
