defmodule Kubeybilly.FixtureBundles do
  @moduledoc """
  Loads recorded incident bundles for the signature replay corpus.

  Every captured bundle under `test/fixtures/incidents/` is a test fixture
  for free because matchers are pure functions over a bundle; this helper
  keeps the loading one-liner out of every matcher test.
  """

  alias Kubeybilly.Signatures.LoadedBundle

  @fixtures_root "test/fixtures/incidents"

  @spec load!(String.t()) :: LoadedBundle.t()
  def load!(name) do
    {:ok, bundle} = LoadedBundle.load(Path.join(@fixtures_root, name))
    bundle
  end
end
