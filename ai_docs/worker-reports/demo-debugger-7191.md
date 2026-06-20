# Worker report: demo-debugger (idle)

# Diagnosis: `MyApp.Inventory.reserve/2`

This is a pure code analysis — no repo access used.

## 1. Root cause — classic **TOCTOU / read‑modify‑write race** (a.k.a. "lost update")

The function performs a **non-atomic read → check → write** against a shared mutable row:

```elixir
item = Repo.get(Item, item_id)                                  # ① READ (stale snapshot)
if item.quantity_on_hand >= quantity do                         # ② CHECK against in-memory value
  item |> Ecto.Changeset.change(quantity_on_hand: ...) |> Repo.update()  # ③ WRITE computed from ①
```

Three things are broken and any one of them alone is sufficient:

- **The check and the write aren't atomic.** Between ② (`if … >=`) and ③ (`Repo.update`), nothing stops another transaction from committing a decrement on the same row. The `UPDATE … SET quantity_on_hand = <value computed from the stale read>` then **blindly overwrites** the concurrent change — a textbook *lost update*.
- **`Ecto.Changeset.change/2` writes an absolute value**, not a relative decrement. So the column gets set to `stale_read − quantity`, trampling whatever the concurrent writer just did.
- **The returned value is derived from the stale in-memory struct**, not reloaded: `{:ok, item.quantity_on_hand - quantity}`. The number you hand back to the caller can be wrong even when the DB is fine.

There is no `FOR UPDATE`, no transaction, no `optimistic_lock`, and no atomic conditional `UPDATE` — so PostgreSQL has no idea these statements are meant to be one atomic operation.

## 2. Concurrent trace

Initial state: `items.id = 1, quantity_on_hand = 1`. Two calls land near‑simultaneously: `reserve(1, 1)` from process **A** and `reserve(1, 1)` from process **B**.

| t | Process A | Process B | DB `qoh` |
|---|-----------|-----------|----------|
| t0 | `Repo.get` → reads **1** | | 1 |
| t1 | | `Repo.get` → reads **1** (its own snapshot) | 1 |
| t2 | `if 1 >= 1` → **true** | | 1 |
| t3 | | `if 1 >= 1` → **true** | 1 |
| t4 | `UPDATE … SET qoh = 1 − 1 = 0` → commits | | 0 |
| t5 | `{:ok, 0}` | `UPDATE … SET qoh = 1 − 1 = 0` → commits (A's decrement is **lost**) | 0 |
| t6 | | `{:ok, 0}` | 0 |

We sold **2 units** of an item that had **1**, both callers got `{:ok, _}`, no error. This is exactly the reported symptom.

> **Precision note on "goes negative":** with this *absolute-write* code, the column itself lands at a non‑negative but **wrong (too high)** value via the lost update — it won't literally read `−1`. The **negative** the nightly reconciliation surfaces is the *effective/logical* stock it recomputes as `physical_count − Σ reservations`. (If the column is ever literally negative in your real code, there's also a relative‑decrement path somewhere — but the race class and the fix are identical.) Either way: **overselling via TOCTOU lost update.**

## 3. Fixes

### ✅ Recommended — Atomic conditional `UPDATE` (single statement)

```elixir
defmodule MyApp.Inventory do
  use MyApp.Context  # or:  import Ecto.Query
  alias MyApp.Repo
  alias MyApp.Inventory.Item

  @spec reserve(pos_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :insufficient_stock}
  def reserve(item_id, quantity) do
    query =
      from(i in Item,
        where: i.id == ^item_id and i.quantity_on_hand >= ^quantity,
        update: [inc: [quantity_on_hand: -^quantity]]
      )

    case Repo.update_all(query, [], returning: [:quantity_on_hand]) do
      {1, [%{quantity_on_hand: new_qty}]} -> {:ok, new_qty}
      {0, _} -> {:error, :insufficient_stock}
    end
  end
end
```

**Why it closes the hole:** it's one statement, so the guard (`qoh >= quantity`) and the decrement are evaluated together inside PostgreSQL. Postgres serializes concurrent `UPDATE`s on the same row with a row lock held **only for the duration of the statement**; under READ COMMITTED the second updater waits, then re‑reads the row and re‑checks the `WHERE` against the *fresh* value. If A took the last unit, B's `WHERE qoh >= 1` is now false → `update_all` affects **0 rows** → B cleanly returns `{:error, :insufficient_stock}`. The new value comes straight from `RETURNING`, so it's never stale.

### Alternative A — Pessimistic row lock (`SELECT … FOR UPDATE` in a txn)

```elixir
def reserve(item_id, quantity) do
  Repo.transaction(fn ->
    item =
      from(i in Item, where: i.id == ^item_id, lock: "FOR UPDATE")
      |> Repo.one!()

    if item.quantity_on_hand >= quantity do
      {:ok, _} =
        item
        |> Ecto.Changeset.change(quantity_on_hand: item.quantity_on_hand - quantity)
        |> Repo.update()

      item.quantity_on_hand - quantity
    else
      Repo.rollback(:insufficient_stock)
    end
  end)
  |> case do
    {:ok, new_qty} -> {:ok, new_qty}
    {:error, :insufficient_stock} -> {:error, :insufficient_stock}
  end
end
```

The `FOR UPDATE` lock serializes readers; the second transaction blocks at `Repo.one/1` until the first commits, then sees the updated row.

### Alternative B — Optimistic locking (`lock_version` + retry)

Requires adding a `lock_version :integer` column + `optimistic_lock(:lock_version)` in the changeset. On the stale‑row `Repo.update`, you get `{:error, changeset}` and retry the whole read‑check‑write. Good when contention is rare and you can't hold locks long.

### Alternative C — GenServer serializing the item (per‑item registry/lock)
Spawns one owner process per item; all reserves route through it. **Not recommended as the primary guard**: it only works within a node (multi‑node Phoenix with a load balancer defeats it), it's a throughput bottleneck, and the process mailbox/registry becomes a new failure surface. The DB is the only correct coordination point in a multi‑node setup.

## 4. Tradeoffs / edge cases

| Option | Contention | Retries / storms | Deadlock risk | Schema change | Multi‑node safe | Notes |
|---|---|---|---|---|---|---|
| **Atomic conditional UPDATE** ✅ | Lowest — lock held for one statement | None — fail‑fast `{0, _}` | None on a single‑row update | None | Yes | Best default. Returns `RETURNING` value; no stale read possible. |
| Pessimistic `FOR UPDATE` | Higher — lock held for whole txn (incl. any other work) | None — waiters block | Can deadlock if you lock multiple rows in different orders | None | Yes | Fine when the transaction does more than the decrement (e.g. writes a reservation row in the same txn, which you almost certainly want). **Lock rows in a stable order** if you touch >1. |
| Optimistic `lock_version` | None while idle; spikes under contention | Yes — retry storms possible on hot items | None | Yes (new column) | Yes | Loses badly under flash‑sale traffic; retry amplifies load on the exact hot row. |
| GenServer owner | High (serialized per item) | None | None | None | **No** (without distributed registry) | Fragile; rely only on the DB. |

**Edge cases to handle explicitly:**
- **Return value:** every option must return the *post‑update* `qoh`. The original returns a stale figure — fix it in all variants (the atomic version gets it from `RETURNING`; the others should reload or compute from the locked row).
- **Negative `quantity`:** the `@spec` allows `non_neg_integer()`, so `reserve(id, 0)` is currently valid. `inc: [qoh: -0]` is a harmless no‑op; decide whether you want to reject `0`/negatives up front.
- **Item not found:** none of these distinguish "missing item" from "insufficient stock" — `Repo.one!` raises (txn rolls back), and the atomic `UPDATE` returns `{0, _}`. If you need a distinct `{:error, :not_found}`, check existence first (cheap, non‑locking).
- **Reporting/audit:** if you also insert a reservation/ledger row, do it in the **same transaction** as the lock so stock and ledger can't diverge.

**My pick:** the **atomic conditional `UPDATE`** for the decrement itself (cheapest, correct, multi‑node, zero retries). If a reservation row must be written atomically with the decrement, wrap the *single* conditional `UPDATE` plus the insert in a short `Repo.transaction` and use `FOR UPDATE` on the item — but keep the conditional `WHERE` so the check and write stay inseparable.

## 5. One‑line verdict

**Not a BEAM race at all — it's a database‑level TOCTOU / lost‑update race;** the BEAM's per‑process heaps and message passing offer zero protection here because the shared mutable state lives in PostgreSQL, so the fix must be enforced by the database (locking or an atomic conditional `UPDATE`), never by relying on Elixir/Erlang's concurrency model.
