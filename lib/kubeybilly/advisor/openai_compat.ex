defmodule Kubeybilly.Advisor.OpenAICompat do
  @moduledoc """
  One Req-based adapter for every OpenAI-compatible chat completions host.

  Scaleway Generative APIs, OpenAI, Ollama, and vLLM all converged on the
  same wire format, so a single adapter covers them and the provider is
  nothing but config: base URL, model name, and the env var naming the
  key (plan/14). The key itself is read at call time and never stored.

  The proposal call asks for JSON mode and embeds the schema and the
  closed formulary in the system prompt, but prompting is a wish, not a
  contract: a reply that fails to parse or validate is retried exactly
  once with the validation error appended to the conversation, then the
  adapter gives up with `{:error, {:model_output_invalid, detail}}` and
  the facade turns that into the `no_action` fallback. Never a third
  call. Req's own retries are disabled so this discipline is the only
  retry policy in play.
  """

  @behaviour Kubeybilly.Advisor

  alias Kubeybilly.Advisor.Proposal
  alias Kubeybilly.Formulary.Action

  @completions_path "/chat/completions"

  # Rendered from the formulary itself so the prompt cannot drift from
  # what Action.new/2 will accept. Probing real models showed that
  # without these names they invent plausible ones ("deployment") and
  # every mitigation proposal dies in validation.
  @formulary_lines Enum.map_join(Action.required_params(), "\n", fn {action, params} ->
                     "- #{action} (params: #{Enum.map_join(params, ", ", &Atom.to_string/1)})"
                   end)

  @propose_prompt """
  You are KubeyBilly's fallback classifier for Kubernetes incidents that \
  matched no deterministic signature. Given an evidence bundle summary, \
  propose at most one recovery action. You may ONLY choose an action from \
  this closed formulary; no other action exists:

  #{@formulary_lines}

  Use exactly the parameter names listed for the action you choose. Any \
  other key is rejected and the proposal is discarded.

  Respond with ONLY a JSON object conforming to this schema, no prose \
  around it:

  {
    "action": "<one formulary name>",
    "params": {"<parameter>": "<value>"},
    "confidence": <number between 0 and 1>,
    "rationale": "<one or two sentences citing the evidence>"
  }

  When the evidence is ambiguous or the fix is outside the formulary, \
  choose "no_action" with params {"reason": "<why>"}.
  """

  @narrate_prompt """
  You are KubeyBilly's scribe. Turn the structured record of a closed \
  Kubernetes incident into a short, plain-prose narrative for the human \
  reading the log. State only what the record states; never invent \
  timestamps, actions, or causes. A few sentences, no headings, no lists.
  """

  @impl Kubeybilly.Advisor
  def propose(summary) when is_map(summary) do
    with {:ok, env} <- load_env() do
      messages = [
        %{role: "system", content: @propose_prompt},
        %{role: "user", content: "Incident summary:\n" <> Jason.encode!(summary)}
      ]

      request_proposal(env, messages, _retries_left = 1)
    end
  end

  @impl Kubeybilly.Advisor
  def narrate(incident_record) when is_map(incident_record) do
    with {:ok, env} <- load_env() do
      messages = [
        %{role: "system", content: @narrate_prompt},
        %{role: "user", content: "Incident record:\n" <> Jason.encode!(incident_record)}
      ]

      complete(env, messages, json_mode: false)
    end
  end

  ## The one-retry discipline

  defp request_proposal(env, messages, retries_left) do
    with {:ok, content} <- complete(env, messages, json_mode: true) do
      case parse(content) do
        {:ok, proposal} ->
          {:ok, proposal}

        {:error, detail} when retries_left > 0 ->
          request_proposal(env, messages ++ correction(content, detail), retries_left - 1)

        {:error, detail} ->
          {:error, {:model_output_invalid, detail}}
      end
    end
  end

  defp parse(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> Proposal.validate(decoded)
      {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp correction(content, detail) do
    [
      %{role: "assistant", content: content},
      %{
        role: "user",
        content:
          "Your previous reply was rejected: #{inspect(detail)}. " <>
            "Respond again with ONLY a JSON object conforming to the schema."
      }
    ]
  end

  ## The wire

  defp complete(env, messages, json_mode: json_mode) do
    body =
      if json_mode do
        %{model: env.model, messages: messages, response_format: %{type: "json_object"}}
      else
        %{model: env.model, messages: messages}
      end

    [
      base_url: env.base_url,
      auth: {:bearer, env.api_key},
      receive_timeout: env.timeout_ms,
      retry: false
    ]
    |> Keyword.merge(env.req_options)
    |> Req.new()
    |> Req.post(url: @completions_path, json: body)
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    case get_in(body, ["choices", Access.at(0), "message", "content"]) do
      content when is_binary(content) -> {:ok, content}
      _missing -> {:error, {:model_output_invalid, :missing_content}}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:http_status, status}}

  defp handle_response({:error, %Req.TransportError{reason: reason}}),
    do: {:error, {:transport, reason}}

  defp handle_response({:error, exception}),
    do: {:error, {:transport, exception}}

  ## Config

  defp load_env do
    config = Application.fetch_env!(:kubeybilly, :advisor)

    case api_key(config) do
      {:ok, api_key} ->
        {:ok,
         %{
           api_key: api_key,
           base_url: Keyword.fetch!(config, :base_url),
           model: Keyword.fetch!(config, :model),
           timeout_ms: Keyword.fetch!(config, :timeout_ms),
           req_options: Keyword.get(config, :req_options, [])
         }}

      :error ->
        {:error, :no_api_key}
    end
  end

  defp api_key(config) do
    case config |> Keyword.fetch!(:api_key_env) |> System.get_env() do
      key when is_binary(key) and key != "" -> {:ok, key}
      _missing -> :error
    end
  end
end
