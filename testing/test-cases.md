# Test Cases

## Test Case Template

| ID | Description | Steps | Expected Result | Status |
|----|-------------|-------|-----------------|--------|
| TC-001 | [What is being tested] | 1. [Action]<br/>2. [Action]<br/>3. [Verify] | [Expected outcome] | ⬜ |

## Example: Agent CRUD Operations

| ID | Description | Steps | Expected Result | Status |
|----|-------------|-------|-----------------|--------|
| TC-101 | Create agent with valid inputs | 1. Navigate to agent creation form<br/>2. Fill name, type, config<br/>3. Click "Create" | Agent created, appears in list, ID assigned | ⬜ |
| TC-102 | Create agent with missing required field | 1. Navigate to creation form<br/>2. Leave "name" empty<br/>3. Click "Create" | Form validation error shown, agent not created | ⬜ |
| TC-103 | Edit agent configuration | 1. Open existing agent<br/>2. Change config value<br/>3. Click "Save" | Changes persisted, confirmation shown | ⬜ |
| TC-104 | Archive running agent | 1. Start agent workflow<br/>2. Click "Archive"<br/>3. Verify UI state | Archive blocked while running, error message shown | ⬜ |
| TC-105 | Delete archived agent | 1. Open archived agent<br/>2. Click "Delete"<br/>3. Confirm dialog | Agent removed from list, cannot be recovered | ⬜ |
| TC-106 | List agents with filters | 1. Navigate to agents page<br/>2. Filter by status="archived"<br/>3. Apply filter | Only archived agents shown, others hidden | ⬜ |

## Regression Test Cases

Use these to catch regressions after changes to core systems:

| ID | Description | Steps | Expected Result | Status |
|----|-------------|-------|-----------------|--------|
| TC-201 | Login persists across page reload | 1. Log in<br/>2. Refresh page<br/>3. Verify still logged in | Session preserved, no re-auth required | ⬜ |
| TC-202 | Concurrent agent workflows don't interfere | 1. Start agent A<br/>2. Start agent B<br/>3. Both produce independent logs | No cross-contamination in logs | ⬜ |
| TC-203 | Large log output doesn't crash console | 1. Generate 10k+ log lines<br/>2. Scroll and search<br/>3. Measure memory/performance | Console responsive, <1s search time | ⬜ |
| TC-204 | Agent state persists after orchestrator restart | 1. Create and configure agent<br/>2. Restart orchestrator service<br/>3. Verify agent state/config intact | Agent data fully restored, no data loss | ⬜ |

## Notes
- Use ⬜ for To Do, 🟦 for In Progress, ✅ for Pass, ❌ for Fail
- Link test cases to requirements (e.g., REQ-050 → TC-105)
- Add "Severity" column if defects are logged (Critical/High/Med/Low)
