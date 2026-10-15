# Snowflake Demos

Generic, self-contained Snowflake demos that anyone can run in their own Snowflake account.

This repository is managed by my [XO](https://github.com/Snowflake-Labs/coco-skills/tree/main/plugins/xo) instance, an operator workflow system for Cortex Code. The instructions below tell an agent how to add, update, retire and organise demos, and they're just as readable for humans. If you want to run or extend these demos, I'd recommend doing it with XO too.

## Rules

1. **Public and generic.** This repository is public. Demos use public or synthetic data only. No customer names, customer data, account identifiers, internal URLs or anything that ties a demo to a specific organisation.
2. **Runs in any account.** A demo must work from a clean Snowflake account with nothing hard-coded to one environment. Put account-specific values (account, user, warehouse, external hosts) in parameters or a `.env.example`. Before running anything, check the active connection and confirm it's the account the operator intends.
3. **No secrets in git.** Keys, `.env` files, `profile.json`, passwords, PATs and Terraform state never get committed. Commit a `.env.example` (or equivalent) with placeholders instead. Check `git status` before every commit and add `.gitignore` entries when a demo introduces a new kind of local secret.
4. **No large binaries or generated output.** No wheels, platform binaries, virtualenvs, logs or downloaded datasets over a few MB. Document how to fetch or build them instead.
5. **No private tracking references.** Commit messages, READMEs and code describe work by its purpose, never by work item number.
6. **Least privilege.** Demo setup creates its own role and grants only what the demo needs. Don't rely on ACCOUNTADMIN beyond the one-off setup steps that genuinely require it, and call those out.

## Layout

```
snowflake-demos/
├── README.md               This file: rules and the demo index
├── <product-area>/         e.g. openflow, cortex, snowpark, streaming
│   └── <demo-name>/        One self-contained demo (kebab-case)
└── terraform/              Shared external infrastructure (e.g. AWS), created when first needed
```

- Group demos by the **primary** Snowflake product they show. Create a new product-area folder only when the first demo for it arrives; delete it when its last demo goes.
- A demo folder is self-contained. Shared assets go in `terraform/` (external infra) or are copied in; demos must not reach into each other's folders.
- Demo names describe what the demo does (e.g. `postgres-cdc`), never who it was built for.

## What every demo contains

Each demo folder has a `README.md` with these sections, in this order:

1. **Title and one-paragraph summary**: what it shows and the story it tells.
2. **Prerequisites**: features, roles, external infra, local tools.
3. **Setup**: numbered steps or a single script, runnable from a clean account.
4. **Run the demo**: the walkthrough, including the "aha" moment.
5. **Teardown**: how to remove every Snowflake object and external resource the demo created.
6. **Status**: `Last verified: YYYY-MM-DD`, plus known issues.

Snowflake objects created by a demo use a single dedicated database (e.g. `DEMO_<NAME>`) and role where practical, so teardown is a `DROP DATABASE` and `DROP ROLE` rather than a hunt. SQL lives in numbered files (`01_setup.sql`, `02_...`, `99_teardown.sql`) so it can be run in order.

A demo may also ship a CoCo skill (`SKILL.md`) to drive it interactively, but the README must stand on its own.

## Workflows

### Build a new demo

1. Check the index below: extend an existing demo if it covers the same story.
2. Create `<product-area>/<demo-name>/` on a feature branch (`demo/<demo-name>`).
3. Build and run it end to end in a Snowflake account, including teardown.
4. Write the README to the template above with today's `Last verified` date.
5. Add a row to the index below, then commit and raise a PR.

### Update an existing demo

1. Read its README first and check its `Last verified` date.
2. Make the change on a feature branch, re-run the affected steps and teardown.
3. Update the README (including `Last verified`) and the index row if the description changed.

### Retire a demo

1. Confirm with the operator. Make sure its teardown has been run so nothing is left billing in the account.
2. Delete the folder, remove its index row, remove the product-area folder if now empty.
3. Commit with a message naming the demo, so it can be found in history (`git log --all -- <path>`) and restored.

### Keep the repository tidy

When working here, flag (don't silently fix) anything that breaks these rules: demos missing from the index, index rows with no folder, untracked folders, committed secrets or binaries, and demos not verified in over six months. Offer to retire or re-verify stale demos.

## Demo index

Keep this table in sync with the folders. One row per demo.

| Demo | Product area | Summary | Last verified |
|------|--------------|---------|---------------|

No demos yet.
