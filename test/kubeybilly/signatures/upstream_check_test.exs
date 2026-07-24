defmodule Kubeybilly.Signatures.UpstreamCheckTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.UpstreamCheck

  test "flags a pod whose env references a service with zero ready endpoints" do
    bundle = FixtureBundles.load!("upstream-down")

    assert {:upstream_down, reason} = UpstreamCheck.check(bundle)
    assert reason =~ "backend"
    assert reason =~ "BACKEND_HOST"
    assert reason =~ "zero ready endpoints"
  end

  test "is clear when every referenced service has ready endpoints" do
    bundle = FixtureBundles.load!("crashloop-post-rollout")

    assert UpstreamCheck.check(bundle) == :clear
  end

  test "is clear on the real capture, whose env references are all healthy" do
    bundle = FixtureBundles.load!("oomkill-galley")

    assert UpstreamCheck.check(bundle) == :clear
  end

  test "is clear when the bundle has no baseline to consult" do
    {:ok, bundle} = LoadedBundle.load("test/fixtures/incidents/upstream-down")
    bundle = %{bundle | baseline: nil}

    assert UpstreamCheck.check(bundle) == :clear
  end
end
