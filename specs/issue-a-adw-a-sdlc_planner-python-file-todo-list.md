# Feature: Python File-Based Project Todo List

## Metadata
adw_id: `a`

## Description
A command-line Python application that stores a todo list in a local JSON file. Users can add, list, complete, and delete tasks from the terminal. All state is persisted to a single `todos.json` file in the project directory.

## Problem Statement
Need a lightweight, dependency-free todo list that lives next to a project and persists between sessions without requiring a database or web service.

## Solution Statement
Build a single-file Python CLI (`todo.py`) that reads/writes a JSON file (`todos.json`). Tasks have an id, title, done flag, and created timestamp. The CLI supports four subcommands: `add`, `list`, `done`, and `delete`.

## Relevant Files

- `todo.py` — main CLI entrypoint; all logic lives here
- `todos.json` — runtime data file (created on first `add`; not committed)
- `tests/test_todo.py` — pytest unit and integration tests

### New Files

- `todo.py`
- `tests/__init__.py`
- `tests/test_todo.py`
- `.gitignore` — excludes `todos.json` and `__pycache__`

## Step by Step Tasks

### 1. Bootstrap the project structure
- Create the workspace directory layout: root `todo.py`, `tests/` package
- Add `.gitignore` with `todos.json`, `__pycache__/`, `*.pyc`, `.pytest_cache/`

### 2. Implement the data model and file I/O
- Define a `Task` TypedDict with fields: `id: int`, `title: str`, `done: bool`, `created_at: str` (ISO-8601)
- Implement `load_todos(path: str) -> list[Task]` — reads `todos.json`; returns `[]` if file absent
- Implement `save_todos(todos: list[Task], path: str) -> None` — atomic write via temp file + `os.replace`
- Implement `next_id(todos: list[Task]) -> int` — returns `max(t["id"] for t in todos) + 1` or `1`

### 3. Implement the four CLI commands
- `add(title: str, path: str) -> Task` — creates a task, appends it, saves, prints confirmation
- `list_todos(path: str, show_done: bool) -> None` — prints a formatted table; `[x]` vs `[ ]` prefix
- `mark_done(task_id: int, path: str) -> None` — sets `done=True` and saves; errors if id not found
- `delete(task_id: int, path: str) -> None` — removes by id and saves; errors if id not found

### 4. Wire up argparse
- Top-level parser with `--file` option (default `todos.json`)
- Subcommands: `add <title>`, `list [--all]`, `done <id>`, `delete <id>`
- `main()` dispatches to the four command functions; `sys.exit(1)` on errors

### 5. Write tests
- `tests/test_todo.py` using `pytest` and `tmp_path` fixture for isolated file I/O
- Test `add`: creates file, correct fields, sequential ids
- Test `list_todos`: empty list, one task, mixed done/pending, `--all` flag
- Test `mark_done`: success case, unknown id raises `SystemExit`
- Test `delete`: success case, unknown id raises `SystemExit`
- Test atomic write: simulate mid-write crash does not corrupt existing file

### 6. Run validation
- Execute all validation commands below and confirm zero failures

## Acceptance Criteria
- `python todo.py add "Buy milk"` prints `Added task #1: Buy milk`
- `python todo.py list` shows pending tasks only by default
- `python todo.py done 1` marks task 1 complete; `list` no longer shows it without `--all`
- `python todo.py delete 1` removes the task; subsequent `list --all` confirms removal
- `python todo.py list` on an empty/missing `todos.json` prints `No tasks.` and exits 0
- Unknown id for `done`/`delete` prints an error to stderr and exits 1
- All pytest tests pass

## Validation Commands

```bash
# Lint and type-check
python -m py_compile todo.py

# Run the test suite
python -m pytest tests/ -v

# Manual smoke test (requires clean state)
rm -f todos.json
python todo.py add "Buy milk"
python todo.py add "Write tests"
python todo.py list
python todo.py done 1
python todo.py list
python todo.py list --all
python todo.py delete 2
python todo.py list --all
```

## Notes
- No third-party runtime dependencies — stdlib only (`argparse`, `json`, `os`, `sys`, `datetime`).
- `pytest` is the only dev dependency.
- The atomic write pattern (`tempfile` + `os.replace`) prevents corruption on crash.
- TypedDict is used for the task shape so editors and mypy can catch field-name typos without adding a runtime dependency.
