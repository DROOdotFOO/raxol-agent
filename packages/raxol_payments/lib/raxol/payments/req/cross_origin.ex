defmodule Raxol.Payments.Req.CrossOrigin do
  @moduledoc false
  # Req's redirect step drops only `authorization` when a redirect leaves the
  # origin; any other credential header goes with it. `attach/3` adds a
  # response step, run before `:redirect`, that removes `headers` from the
  # request when the response redirects to another scheme, host or port. A
  # same-origin redirect (a trailing-slash 308, say) keeps them.

  @redirects [301, 302, 303, 307, 308]

  @spec attach(Req.Request.t(), atom(), [String.t()]) :: Req.Request.t()
  def attach(%Req.Request{} = req, step_name, headers) do
    Req.Request.prepend_response_steps(req, [{step_name, &strip(&1, headers)}])
  end

  defp strip({request, %Req.Response{status: status} = response}, headers)
       when status in @redirects do
    case Req.Response.get_header(response, "location") do
      [location | _] ->
        if same_origin?(request.url, location),
          do: {request, response},
          else: {Enum.reduce(headers, request, &Req.Request.delete_header(&2, &1)), response}

      [] ->
        {request, response}
    end
  end

  defp strip(request_response, _headers), do: request_response

  defp same_origin?(url, location) do
    from = URI.parse(url)
    to = URI.merge(from, location)
    origin(from) == origin(to)
  rescue
    _ -> false
  end

  defp origin(%URI{scheme: scheme, host: host, port: port}),
    do: {scheme && String.downcase(scheme), host && String.downcase(host), port}
end
