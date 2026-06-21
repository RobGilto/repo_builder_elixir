# Manual Smoke Test Checklist

**Test Date**: ___________  **Tester**: ___________  **Version**: ___________

## Setup
- [ ] Fresh database (or reset test fixtures)
- [ ] App running locally (`mix phx.server`)
- [ ] Browser dev tools open (monitor console errors)
- [ ] Network tab monitored (check for failed requests)

## Core Workflows

### Agent Management
- [ ] Create a new agent via form (verify ID assigned)
- [ ] Edit agent configuration (verify changes saved)
- [ ] List agents (verify filters work: by status, type)
- [ ] Archive an agent (verify state transitions correctly)
- [ ] Soft-delete archived agent (verify not recoverable)

### Orchestrator Console
- [ ] Navigate to console home page
- [ ] Start a workflow (verify swimlane appears)
- [ ] Monitor live log streaming (verify no latency/drops)
- [ ] Pause/resume workflow (verify state updates)
- [ ] Clear swimlanes (verify CLEAR removes all running agents)

### UI & Navigation
- [ ] Modal focus trap (⌘K opens, focus stays in modal)
- [ ] Keyboard shortcuts work (⌘K, ESC to close)
- [ ] Responsive layout (test on mobile viewport)
- [ ] Dark/light theme toggle (persists on reload)
- [ ] No console JavaScript errors in dev tools

### Data Validation
- [ ] Submit empty required field (form error shown)
- [ ] Submit invalid log number (error message appears)
- [ ] Large dataset (10k+ logs) loads without hang
- [ ] Search/filter performance acceptable (<500ms)

### Integration Points
- [ ] Agent logs appear in console feed
- [ ] Orchestrator tool calls work (via MCP)
- [ ] Database writes persist after reload
- [ ] API responses have correct status codes

## Performance Checks
- [ ] Page load time < 2s
- [ ] Scroll performance smooth (60fps)
- [ ] No memory leaks (check heap snapshot before/after)
- [ ] Database queries efficient (check slow query logs)

## Browser Compatibility (if applicable)
- [ ] Chrome/Chromium (latest)
- [ ] Firefox (latest)
- [ ] Safari (latest)

## State Persistence & Recovery
- [ ] Agent state survives orchestrator restart
- [ ] Console history persists across sessions
- [ ] Workflow state correctly restored after crash

## Sign-Off
- [ ] All checks passed (or exceptions noted below)
- [ ] No critical defects found
- [ ] Ready for deployment

### Exceptions / Notes
```
[List any items that failed or were skipped with reasons]
```

**Tester Signature**: ___________  **Date**: ___________
