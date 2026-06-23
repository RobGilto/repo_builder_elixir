---
description: Run the Python (uv) test + lint gate and report
argument-hint: [filter]
---

# Test (Python / uv)

Run the gate with `uv`, reporting each command:

1. `uv run ruff check`
2. `uv run pyright`
3. `uv run pytest` (append `$ARGUMENTS` as a node id / `-k` filter when provided)

On failure, surface the failing output verbatim and propose the smallest fix.
