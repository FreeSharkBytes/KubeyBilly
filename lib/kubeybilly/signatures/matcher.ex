defmodule Kubeybilly.Signatures.Matcher do
  @moduledoc """
  The contract every deterministic signature detector implements.

  A matcher is a pure function from a frozen evidence bundle to a verdict:
  it reads only the `LoadedBundle`, never the live cluster, so every
  detector is unit-testable without a cluster, replayable against the
  recorded incident corpus, and deterministic on stage. Triage treats all
  matchers uniformly through this behaviour, which is what lets priority
  ordering live in one list instead of in the detectors themselves.
  """

  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Signature

  @callback match(LoadedBundle.t()) :: {:match, Signature.t()} | :no_match
end
