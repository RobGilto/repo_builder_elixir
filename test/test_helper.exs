# :live_acceptance drives the REAL agent CLIs (claude/pi) — excluded by default so CI
# and local runs stay Fake-adapter-only. Opt in with:
#   mix test --only live_acceptance
ExUnit.start(exclude: [:live_acceptance])
Ecto.Adapters.SQL.Sandbox.mode(RepoBuilder.Repo, :manual)
