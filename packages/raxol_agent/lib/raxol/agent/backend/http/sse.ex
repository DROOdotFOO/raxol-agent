defmodule Raxol.Agent.Backend.HTTP.SSE do
  @moduledoc false
  # Server-sent-event framing and per-provider event decoding for the
  # streaming path of `Raxol.Agent.Backend.HTTP`.

  alias Raxol.Agent.Backend.HTTP.Choice

  @type event ::
          {:text_delta, String.t()}
          | {:reasoning_delta, String.t()}
          | {:tool_call_delta, [map()]}
          | {:usage, map()}
          | {:marker, String.t()}

  @doc """
  Whether appending `data` to `buffer` can complete an event: a newline for
  Ollama, a blank line otherwise, CRLF read as LF as `parse/2` does. Only the buffer's last three
  bytes are looked at, for a separator split across chunks.
  """
  @spec boundary?(String.t(), String.t(), atom()) :: boolean()
  def boundary?(buffer, data, provider) do
    size = byte_size(buffer)
    window = binary_part(buffer, max(size - 3, 0), min(size, 3)) <> data

    case provider do
      :ollama -> String.contains?(window, "\n")
      _ -> window |> String.replace("\r\n", "\n") |> String.contains?("\n\n")
    end
  end

  @doc """
  Split `raw` into complete events and the unterminated remainder, which the
  caller prepends to the next chunk. Ollama streams newline-delimited JSON;
  the others stream `data:` records separated by a blank line.
  """
  @spec parse(String.t(), atom()) :: {[event()], String.t()}
  def parse(raw, :ollama) do
    {complete, [buffer]} = raw |> String.split("\n") |> Enum.split(-1)

    events =
      complete
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"done" => true}} -> [{:usage, %{}}]
          {:ok, %{"message" => %{"content" => text}}} -> [{:text_delta, text}]
          _ -> []
        end
      end)

    {events, buffer}
  end

  # CRLF is normalized first: a `\r\n\r\n` separator would otherwise never
  # frame, and a `data: [DONE]\r` line would not match. A lone `\r` split
  # across chunks completes with the next chunk.
  def parse(raw, provider) when provider in [:anthropic, :openai, :kimi] do
    case raw |> String.replace("\r\n", "\n") |> String.split("\n\n") do
      [single] ->
        {[], single}

      parts ->
        {complete, [buffer]} = Enum.split(parts, -1)

        events =
          complete
          |> Enum.reject(&(&1 == ""))
          |> Enum.flat_map(&event(&1, provider))

        {events, buffer}
    end
  end

  defp event(text, :anthropic) do
    with "data: " <> json <- data_line(text),
         {:ok, parsed} <- Jason.decode(json) do
      anthropic_event(parsed)
    else
      _ -> []
    end
  end

  defp event(text, provider) when provider in [:openai, :kimi] do
    case data_line(text) do
      "data: [DONE]" ->
        [{:usage, %{}}]

      "data: " <> data ->
        case Jason.decode(data) do
          {:ok, decoded} -> openai_events(decoded)
          {:error, _} -> [{:marker, "⚠ unparseable response chunk"}]
        end

      # A comment, keep-alive or blank record.
      _ ->
        []
    end
  end

  defp data_line(text),
    do: text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "data: "))

  # Extended thinking streams `thinking_delta` then `signature_delta`; only
  # the thought is surfaced.
  defp anthropic_event(%{"type" => "content_block_delta", "delta" => %{"thinking" => text}})
       when is_binary(text),
       do: [{:reasoning_delta, text}]

  defp anthropic_event(%{"type" => "content_block_delta", "delta" => %{"text" => text}}),
    do: [{:text_delta, text}]

  defp anthropic_event(%{"type" => "message_delta", "usage" => usage}), do: [{:usage, usage}]
  defp anthropic_event(_other), do: []

  # Tool calls are passed on as raw fragments: OpenAI-compatible providers
  # send the id and name on a call's first fragment and its arguments across
  # later ones, so `HTTP.ToolCalls.merge/2` accumulates them by index.
  defp openai_events(%{"choices" => [choice | _]}) when is_map(choice) do
    msg = Choice.message(choice)
    reasoning = Choice.reasoning(msg)
    text = Choice.text(msg)
    tool_calls = msg["tool_calls"]

    [
      reasoning && {:reasoning_delta, reasoning},
      text != "" && {:text_delta, text},
      is_list(tool_calls) and tool_calls != [] and {:tool_call_delta, tool_calls},
      Choice.finish_reason(choice) == "length" && {:marker, Choice.truncation_marker(choice)}
    ]
    |> Enum.filter(& &1)
  end

  # A usage-only chunk with empty `choices` at stream end.
  defp openai_events(%{"usage" => usage}) when is_map(usage), do: [{:usage, usage}]

  # Well-formed JSON in an unknown shape is skipped; only a decode failure
  # is marked.
  defp openai_events(_other), do: []
end
