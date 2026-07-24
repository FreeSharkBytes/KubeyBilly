# Contributing

Thanks for looking at this. A few ground rules keep the safety story reviewable.

## Where work happens

The canonical repo is on
[GitLab](https://gitlab.com/freesharkbytes/kubeybilly/kubeybilly); the GitHub copy is
a read-only mirror. Open issues and merge requests on GitLab.

## Workflow

Branch off `main`, keep commits small (one green step each), and use conventional
commit messages (`feat:`, `fix:`, `test:`, `chore:`, and friends). Add a line to the
Unreleased section of the CHANGELOG when your change is worth a user noticing.

Before pushing, all four gates must pass:

```
mix test
mix format --check-formatted
mix credo --strict
mix compile --warnings-as-errors
```

## Tests come first

This project is test-driven, and the bar is deliberately high on the modules that
make up the safety argument: signatures, standing orders, the formulary, the state
machine, the executor, and verification. Write the failing test, watch it fail, then
implement. Aim for 90 percent line coverage on logic modules. The Kubernetes
boundary is mocked with Mox; no test may require a live cluster or a network call.

If you capture an interesting evidence bundle, consider adding it to
`test/fixtures/incidents/` as a replay fixture. Matchers are pure functions over
bundles, so every real incident can become a regression test.

## Style

- Tagged tuples for errors: `{:ok, value}` and `{:error, reason}`. Do not throw
  exceptions across module boundaries.
- One module per file.
- Moduledocs explain why a thing exists, not how it works. If a comment restates the
  code, delete it.
- Only the executor may make mutating cluster calls. Everything else returns intent.
  This invariant is the whole point of the codebase; changes that blur it will be
  declined.

## Commit signing

Maintainer commits are SSH-signed. Signing your own is welcome but not required.
