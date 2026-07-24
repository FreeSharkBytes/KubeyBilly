defmodule Kubeybilly.Logbook.Sections do
  @moduledoc """
  Renders the factual sections of `log.md` from structured data alone.

  Layer 3 of the decision engine gives prose zero authority (plan/02):
  every line here is derived from the incident record and the bundle
  manifest, never from a model, so the timeline, evidence list, rule
  citations, and undo command cannot be hallucinated. Rendering is
  deterministic on purpose: sorted keys, fixed formats, no wall clock,
  which is what makes the golden-file tests meaningful.
  """

  alias Kubeybilly.Logbook.Fields
  alias Kubeybilly.Logbook.Undo

  @verification_closers [
    :verified_recovered,
    :verified_unchanged,
    :worse_reverting,
    :frozen_after_worse,
    :verification_window_expired
  ]

  @doc "Render the full factual document for a closed record."
  @spec render(term(), map() | nil) :: String.t()
  def render(record, manifest) do
    [
      title(record),
      timeline(record),
      soundings(record, manifest),
      signature(record),
      decision(record),
      action(record),
      verification(record),
      open_questions(record, manifest)
    ]
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  ## Title

  defp title(record) do
    id = Fields.text(Fields.get(record, :id))
    outcome = Fields.text(Fields.get(record, :outcome))
    workload = Fields.get(record, :workload)
    kind = Fields.text(Fields.get(workload, :kind))
    name = Fields.text(Fields.get(workload, :name))
    namespace = Fields.text(Fields.get(record, :namespace))

    """
    # Incident #{id} (#{humanize(outcome)})

    Workload: #{kind} #{name} in namespace #{namespace}. Everything below is
    generated from the structured incident record; no model wrote any of it.\
    """
  end

  ## Timeline

  defp timeline(record) do
    rows =
      record
      |> Fields.get(:timeline)
      |> List.wrap()
      |> Enum.map(fn {at, event, detail} ->
        "| #{stamp(at)} | #{humanize(event)} | #{cell(detail_text(detail))} |"
      end)

    Enum.join(
      [
        "## Timeline",
        "",
        "| Time (UTC) | Event | Detail |",
        "| --- | --- | --- |"
      ] ++ rows,
      "\n"
    )
  end

  ## Soundings

  defp soundings(record, nil) do
    id = Fields.text(Fields.get(record, :id))

    """
    ## Soundings

    No manifest was found for bundle #{id}, so what was captured cannot be
    listed here. Treat the evidence as incomplete.\
    """
  end

  defp soundings(_record, manifest) do
    header = [
      "## Soundings",
      "",
      "The evidence bundle was captured at #{manifest["captured_at"]}, before " <>
        "anything was touched. Paths are relative to the incident directory.",
      ""
    ]

    Enum.join(header ++ files_table(manifest["files"]) ++ ["", gaps_line(manifest)], "\n")
  end

  defp files_table([]), do: ["The manifest lists no captured files."]
  defp files_table(nil), do: ["The manifest lists no captured files."]

  defp files_table(files) do
    rows = Enum.map(files, fn file -> "| #{cell(file["path"])} | #{file["bytes"]} |" end)
    ["| Artifact | Bytes |", "| --- | --- |"] ++ rows
  end

  defp gaps_line(manifest) do
    case gaps(manifest) do
      [] ->
        "No gaps were recorded; the capture is complete."

      gaps ->
        Enum.join(
          ["The capture recorded gaps:", ""] ++ Enum.map(gaps, &("- " <> detail_text(&1))),
          "\n"
        )
    end
  end

  defp gaps(manifest), do: manifest |> Fields.get(:gaps) |> List.wrap()

  ## Signature

  defp signature(record) do
    case Fields.get(record, :signature) do
      nil ->
        """
        ## Signature

        No signature matched this incident.\
        """

      signature ->
        refs =
          signature
          |> Fields.get(:evidence_refs)
          |> List.wrap()
          |> Enum.map(&("  - " <> Fields.text(&1)))

        evidence =
          case refs do
            [] -> ["- Evidence: none recorded"]
            refs -> ["- Evidence:"] ++ refs
          end

        Enum.join(
          [
            "## Signature",
            "",
            "- Name: #{Fields.text(Fields.get(signature, :name))}",
            "- Confidence: #{Fields.text(Fields.get(signature, :confidence))}",
            "- Rationale: #{Fields.text(Fields.get(signature, :rationale))}"
          ] ++ evidence,
          "\n"
        )
    end
  end

  ## Decision

  defp decision(record) do
    case Fields.get(record, :decision) do
      nil ->
        """
        ## Decision

        No policy decision was reached.\
        """

      decision ->
        chain =
          decision
          |> Fields.get(:chain)
          |> List.wrap()
          |> Enum.map_join(", ", &Fields.text/1)

        """
        ## Decision

        - Verdict: #{Fields.text(Fields.get(decision, :verdict))}
        - Deciding rule: #{Fields.text(Fields.get(decision, :rule_id))}
        - Rule chain: #{chain}
        - Reason: #{Fields.text(Fields.get(decision, :reason))}\
        """
    end
  end

  ## Action

  defp action(record) do
    case Fields.get(record, :action) do
      nil ->
        """
        ## Action

        No action was validated.\
        """

      action ->
        """
        ## Action

        - Action: #{Fields.text(Fields.get(action, :name))}
        - Params: #{params_text(Fields.get(action, :params))}
        - Undo: `#{Undo.command(action)}`\
        """
    end
  end

  ## Verification

  defp verification(record) do
    outcome = Fields.get(record, :verification_outcome)

    case {outcome, window(record)} do
      {nil, _window} ->
        """
        ## Verification

        No verification ran; the incident closed before any action took effect.\
        """

      {outcome, nil} ->
        """
        ## Verification

        Outcome: #{Fields.text(outcome)}.\
        """

      {outcome, {opened, closed}} ->
        """
        ## Verification

        Outcome: #{Fields.text(outcome)}. The verification window opened at
        #{stamp(opened)} and closed at #{stamp(closed)} (UTC).\
        """
    end
  end

  defp window(record) do
    timeline = record |> Fields.get(:timeline) |> List.wrap()

    with {opened, :executed, _detail} <-
           Enum.find(timeline, :none, fn {_at, event, _detail} -> event == :executed end),
         {closed, _event, _detail} <-
           Enum.find(timeline, :none, fn {_at, event, _detail} ->
             event in @verification_closers
           end) do
      {opened, closed}
    else
      :none -> nil
    end
  end

  ## Open questions

  defp open_questions(record, manifest) do
    questions =
      gap_question(manifest) ++
        escalation_question(record) ++
        upstream_question(record) ++
        budget_question(record)

    case questions do
      [] ->
        """
        ## Open questions

        None. Nothing here is waiting on a human decision.\
        """

      questions ->
        Enum.join(["## Open questions", ""] ++ Enum.map(questions, &("- " <> &1)), "\n")
    end
  end

  defp gap_question(nil), do: []

  defp gap_question(manifest) do
    case gaps(manifest) do
      [] ->
        []

      gaps ->
        [
          "The capture recorded #{length(gaps)} gap(s), listed under Soundings. " <>
            "Can the missing evidence be recovered from another source before it ages out?"
        ]
    end
  end

  defp escalation_question(record) do
    if Fields.text(Fields.get(record, :outcome)) == "escalated" do
      case record |> Fields.get(:timeline) |> List.wrap() |> List.last() do
        {_at, event, detail} ->
          [
            "The incident escalated on \"#{humanize(event)}\" (#{detail_text(detail)}). " <>
              "A human needs to take it from here; the evidence above is the handoff."
          ]

        _none ->
          []
      end
    else
      []
    end
  end

  defp upstream_question(record) do
    signature = Fields.get(record, :signature)

    if Fields.text(Fields.get(signature, :name)) == "upstream_down" do
      [
        "An upstream dependency was down: #{Fields.text(Fields.get(signature, :rationale))} " <>
          "Confirm the upstream has recovered before acting on this workload again."
      ]
    else
      []
    end
  end

  defp budget_question(record) do
    decision = Fields.get(record, :decision)
    rule_id = Fields.text(Fields.get(decision, :rule_id))

    if Fields.text(Fields.get(decision, :verdict)) == "deny" and
         String.starts_with?(rule_id, "budget-") do
      [
        "Rule #{rule_id} refused the action because the budget was spent. " <>
          "Was the refusal right, or does the budget need raising?"
      ]
    else
      []
    end
  end

  ## Shared rendering

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")
  defp stamp(other), do: Fields.text(other)

  defp humanize(value), do: value |> Fields.text() |> String.replace("_", " ")

  defp cell(text) do
    text
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
  end

  defp detail_text(detail) when is_map(detail) do
    detail
    |> Enum.sort_by(fn {key, _value} -> Fields.text(key) end)
    |> Enum.map_join("; ", fn {key, value} ->
      "#{Fields.text(key)}: #{value_text(value)}"
    end)
  end

  defp detail_text(other), do: value_text(other)

  defp value_text(value) when is_map(value) do
    inner =
      value
      |> Enum.sort_by(fn {key, _v} -> Fields.text(key) end)
      |> Enum.map_join("; ", fn {key, v} -> "#{Fields.text(key)}: #{value_text(v)}" end)

    "{" <> inner <> "}"
  end

  defp value_text(value) when is_list(value), do: Enum.map_join(value, ", ", &value_text/1)
  defp value_text(value), do: Fields.text(value)

  defp params_text(nil), do: "none"

  defp params_text(params) when is_map(params) and map_size(params) == 0, do: "none"

  defp params_text(params) when is_map(params), do: detail_text(params)

  defp params_text(other), do: Fields.text(other)
end
