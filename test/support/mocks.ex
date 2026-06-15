# Mox mock of the mandatory harness behaviour. Injected via the registry
# (BUILD_PROMPT.md §13) — override the `:harnesses` map entry under test to point
# at this module; never a separate `:harness_adapter` key.
Mox.defmock(RepoBuilder.Harness.Mock, for: RepoBuilder.Harness)
