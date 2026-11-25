defmodule Raxol.Agent.Backend.HTTP.Models do
  @moduledoc false
  # The provider model-list endpoints behind `HTTP.check_auth/1` and
  # `HTTP.list_models/1`. Listing models costs no tokens.

  alias Raxol.Agent.Backend.Anthropic.Wire

  @type request :: {String.t(), [{String.t(), String.t()}]} | :unsupported

  @doc "The `{url, headers}` for `provider`'s model list, or `:unsupported`."
  @spec request(atom(), keyword()) :: request()
  def request(:anthropic, opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) ->
        base = Keyword.get(opts, :base_url, "https://api.anthropic.com")
        {"#{base}/v1/models", [{"x-api-key", key}, {"anthropic-version", Wire.api_version()}]}

      _no_key ->
        :unsupported
    end
  end

  def request(:openai, opts), do: bearer_request(opts, "https://api.openai.com")
  def request(:kimi, opts), do: bearer_request(opts, "https://api.moonshot.ai")

  def request(:ollama, opts),
    do: {"#{Keyword.get(opts, :base_url, "http://localhost:11434")}/api/tags", []}

  def request(_provider, _opts), do: :unsupported

  # `:auth_check_path` names an endpoint that requires the key: `/v1/models`
  # is public on some hosts (OpenRouter), where it would report a revoked
  # key as valid.
  defp bearer_request(opts, default_base) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) ->
        base = Keyword.get(opts, :base_url, default_base)
        path = Keyword.get(opts, :auth_check_path, "/v1/models")
        {"#{base}#{path}", [{"authorization", "Bearer #{key}"}]}

      _no_key ->
        :unsupported
    end
  end

  @spec check(request(), timeout()) ::
          :valid
          | {:rejected, non_neg_integer()}
          | {:reachable_error, non_neg_integer()}
          | :unreachable
          | :unsupported
  def check(:unsupported, _timeout), do: :unsupported

  def check({url, headers}, timeout) do
    case Req.get(Req.new(url: url, headers: headers, receive_timeout: timeout)) do
      {:ok, %{status: status}} -> interpret_status(status)
      {:error, _reason} -> :unreachable
    end
  rescue
    _ -> :unreachable
  end

  @spec list(request(), atom(), timeout()) ::
          {:ok, [String.t()]} | {:error, term()} | :unsupported
  def list(:unsupported, _provider, _timeout), do: :unsupported

  def list({url, headers}, provider, timeout) do
    case Req.get(Req.new(url: url, headers: headers, receive_timeout: timeout)) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, parse(provider, body)}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  @spec interpret_status(integer()) ::
          :valid | {:rejected, 401 | 403} | {:reachable_error, integer()}
  def interpret_status(status) when status in 200..299, do: :valid
  def interpret_status(status) when status in [401, 403], do: {:rejected, status}
  def interpret_status(status) when is_integer(status), do: {:reachable_error, status}

  @doc """
  Model ids from a model-list body: Ollama `/api/tags` lists `models[].name`,
  OpenAI-compatible `/v1/models` lists `data[].id`.
  """
  @spec parse(atom(), term()) :: [String.t()]
  def parse(:ollama, %{"models" => models}) when is_list(models),
    do: for(%{"name" => name} <- models, is_binary(name), do: name)

  def parse(_provider, %{"data" => data}) when is_list(data),
    do: for(%{"id" => id} <- data, is_binary(id), do: id)

  def parse(_provider, _body), do: []
end
