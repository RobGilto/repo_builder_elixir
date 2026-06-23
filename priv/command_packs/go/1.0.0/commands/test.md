---
description: Run the Go test + vet gate and report
argument-hint: [filter]
---

# Test (Go)

Run the gate, reporting each command:

1. `gofmt -l .` (must print nothing)
2. `go vet ./...`
3. `go test ./...` (append `$ARGUMENTS` as a `-run` pattern when provided)

On failure, surface the failing output verbatim and propose the smallest fix.
