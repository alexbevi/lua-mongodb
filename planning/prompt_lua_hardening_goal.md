# Lua architecture hardening goal

```text
/goal Execute the lua-hardening track in planning/plan.json from PLN-001 through REL-048. Read AGENTS.md and use $execute-driver-slice for every activity. Select with `python3 planning/update_plan.py next --track lua-hardening`, start with `python3 planning/update_plan.py start ID --track lua-hardening`, continue one activity at a time, push and wait for CI Fast after each, and stop after REL-048.
```

This prompt is one explicit authorization for the declared `lua-hardening` post-v1 track. It does not authorize any `ADV-*`, `AUTH-*`, or other activity outside that track.
