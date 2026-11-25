defmodule Raxol.Agent.Backend.HTTP.Choice do
  @moduledoc false
  # Field extraction from an OpenAI-compatible `choices[]` entry, shared by
  # the blocking and streaming paths.

  @doc """
  The content-bearing object of a choice: `message` (full-message shape,
  also sent by LongCat on SSE) or `delta` (streaming shape).
  """
  @spec message(map()) :: map()
  def message(%{"message" => msg}) when is_map(msg), do: msg
  def message(%{"delta" => delta}) when is_map(delta), do: delta
  def message(_choice), do: %{}

  @spec text(map()) :: String.t()
  def text(%{"content" => t}) when is_binary(t), do: t
  def text(_msg), do: ""

  @doc "`reasoning_content` (DeepSeek, LongCat) or `reasoning` (OpenRouter); nil when blank."
  @spec reasoning(map()) :: String.t() | nil
  def reasoning(%{"reasoning_content" => t}) when is_binary(t) and t != "", do: t
  def reasoning(%{"reasoning" => t}) when is_binary(t) and t != "", do: t
  def reasoning(_msg), do: nil

  @doc "`finish_reason`, or LongCat's `finishreason`."
  @spec finish_reason(term()) :: String.t() | nil
  def finish_reason(choice) when is_map(choice),
    do: Map.get(choice, "finish_reason") || Map.get(choice, "finishreason")

  def finish_reason(_choice), do: nil

  @doc "The marker for a length-truncated turn, with the token count when known."
  @spec truncation_marker(map()) :: String.t()
  def truncation_marker(source) do
    tokens =
      get_in(source, ["usage", "completion_tokens"]) ||
        get_in(source, ["usage", "total_tokens"])

    suffix = if is_integer(tokens), do: " (#{tokens} tokens)", else: ""
    "⚠ response truncated — hit token limit#{suffix}; raise AI_MAX_TOKENS"
  end
end
