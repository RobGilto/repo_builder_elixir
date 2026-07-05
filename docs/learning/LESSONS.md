# Lessons Ledger — Learning Week 1 (Jul 6–12, 2026)

One entry per day. Each entry answers three things: **what broke** (the bug class, with spec refs), **why** (the underlying mental model that was missing), and **the pattern that prevents it** (phrased so it works as a checklist item on future specs).

Plan: `specs/learning-week-otp-liveview-seams.html`

## Day 1 — Mon Jul 6: OTP Lifecycle I (links, monitors, terminate/2)

**What broke:**

**Why:**

**The pattern that prevents it:**

**Kill → detect → repair timeline observed in IEx:**

## Day 2 — Tue Jul 7: OTP Lifecycle II (derive, don't store)

**What broke:**

**Why:**

**The pattern that prevents it:**

## Day 3 — Wed Jul 8: LiveView lifecycle (mount, reconnect, the second render)

**What broke:**

**Why:**

**The pattern that prevents it:**

**Reconnect audit (state × survives? × why):**

| State | Survives refresh? | Why (persisted vs assign-only) |
|-------|-------------------|--------------------------------|
|       |                   |                                |

## Day 4 — Thu Jul 9: Ecto & data truth (N+1, aggregates, atomic JSONB)

**What broke:**

**Why:**

**The pattern that prevents it:**

**Query counts measured (action × queries before/after):**

## Day 5 — Fri Jul 10: Seam design capstone (the Launch Contract)

**What broke:**

**Why:**

**The pattern that prevents it:**

**Artifacts:** `docs/learning/launch-paths-table.md` · `specs/launch-contract-design.md`

## Day 6 — Sat Jul 11: Failure-mode engineering (fail loud, close the loop)

**What broke:**

**Why:**

**The pattern that prevents it:**

**Silent-failure taxonomy (one sentence):**

## Day 7 — Sun Jul 12: Hygiene, retro & next week

**Spec triage summary:**

**/check-my-understanding score by area:**

- OTP process lifecycle:
- LiveView symmetry:
- Ecto & data truth:
- Seam contracts:
- Failure modes:

**Weak areas scheduled for next week:**

**Next week's headline plan:**

---

## Standing spec-checklist questions (add to every future spec)

1. **What's the second path?** (reconnect, sibling launcher, the other language runtime)
2. **How does it end?** (error payload, cancel, teardown, GC, merge)
