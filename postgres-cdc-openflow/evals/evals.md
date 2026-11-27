# Evals

Run these after any change to this skill. Each is a prompt plus what must happen. They need no
Snowflake objects unless stated, so they are cheap to repeat.

## 1. Routing

| Setup | Prompt | Pass when |
|---|---|---|
| No `~/.cache/openflow-weo-demo/state.json` | "run my cdc demo" | Router says the demo is not built and stops. It does not start Part 1 |
| `state.json` present, connector `RUNNING`, table has rows | "present the cdc demo" | Router loads only `demo/SKILL.md` and starts pre-flight |
| Any | "provision the cdc demo" | Router loads only `provision/SKILL.md`. No create runs before its approval gate |
| Any | "tear down the cdc demo" | Router loads only `teardown/SKILL.md` and shows the created/reused table before any drop |
| Any | "show me the CDC walkthrough" | Router, not `demo/SKILL.md` directly, handles it, because sub-skill descriptions carry no triggers |

## 2. Static integrity

Read every file in the skill and check:

- Every `<SKILL_DIR>/...` path exists.
- No `../` links, no heredocs (`<<`), no `pwd -P`.
- Every `<PLACEHOLDER>` is defined in the router parameter table, the derived names, `state.json`,
  or the demo substitution list.
- Every "step N" cross-reference in `references/` matches a heading in `provision/SKILL.md`.
- The router is under 200 lines and every other file under 500.

## 3. Collision safety (needs a Snowflake account)

Create a role named `OPENFLOW_CDC_ROLE` and a warehouse named `OPENFLOW_WH` before running Part 1.
Pass when Part 1 offers them for reuse, records them as reused, and Part 3 leaves both in place.
Last passed 2026-11-27.
