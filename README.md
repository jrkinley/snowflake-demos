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

Flat: one folder per demo at the repository root, named after the outcome it delivers.

```
snowflake-demos/
├── README.md                 This file: rules and the demo index
├── postgres-cdc-openflow/    A skill demo: the folder is a Cortex Code skill
│   ├── SKILL.md
│   ├── references/           Optional: detail the skill loads on demand
│   └── assets/               Optional: small SQL or config files
└── <another-demo>/           A project demo: README.md plus code, infra, data
```

- **Name by outcome, not product.** Most demos touch several products, so the folder is a short kebab-case slug for what the demo achieves (e.g. `postgres-cdc-openflow`), never who it was built for. Products are recorded in the index, not the folder structure.
- **Self-contained.** A demo never reaches into another demo's folder. Copy shared pieces in rather than linking across.

## Two kinds of demo

**Skill demo (the default).** If a Cortex Code skill can orchestrate the whole demo end to end, the demo *is* the skill: setup, walkthrough and teardown all live in `SKILL.md`, with `references/` and `assets/` for anything too detailed or too large to inline. Anyone can run it by adding the folder to Cortex Code as a skill and asking for the demo.

**Project demo (the exception).** Use this only when a skill cannot carry the demo:

- it needs application code, a container image or a codebase someone works in
- it needs external infrastructure (e.g. Terraform for AWS resources)
- its files exceed what a skill can ship (50 files, 2 MB per file, 10 MB total)

A project demo has a `README.md` and whatever folders it needs (`app/`, `terraform/`, `sql/`, ...). It may also include a `SKILL.md` so an agent can drive it from a clone.

When unsure, start as a skill demo and promote it to a project demo only when it outgrows one.

## What every demo contains

Whichever kind, the entry point (`SKILL.md` or `README.md`) covers, in this order:

1. **Summary**: the outcome and the story it tells, in one paragraph.
2. **Prerequisites**: Snowflake features, privileges, external services and local tools.
3. **Setup**: runnable from a clean account.
4. **Run the demo**: the walkthrough, including the "aha" moment.
5. **Teardown**: removes every Snowflake object and external resource the demo created.
6. **Status**: `Last verified: YYYY-MM-DD`, plus known issues.

Snowflake objects go in a dedicated database and role per demo where practical (e.g. `POSTGRES_CDC_OPENFLOW_DB`), so teardown is a `DROP DATABASE` and `DROP ROLE` rather than a hunt.

Skill demos follow the Cortex Code skill conventions: frontmatter `name` matches the folder, no `README.md` inside the skill, `references/` (plural), and bundled files resolved relative to the skill's own directory, never the working directory.

## Workflows

### Build a new demo

1. Check the index: extend an existing demo if it delivers the same outcome.
2. Decide skill demo or project demo using the test above, and say which and why.
3. Create `<demo-name>/` on a feature branch (`demo/<demo-name>`).
4. Run it end to end in a Snowflake account, including teardown.
5. Write the entry point to the template above with today's `Last verified` date.
6. Add a row to the index, then commit and raise a PR.

### Update an existing demo

1. Read its entry point first and check its `Last verified` date.
2. Make the change on a feature branch, re-run the affected steps and teardown.
3. Update `Last verified`, and the index row if the summary or products changed.

### Retire a demo

1. Confirm with the operator, and make sure its teardown has run so nothing is left billing.
2. Delete the folder and its index row.
3. Commit with a message naming the demo so it can be found in history (`git log --all -- <demo-name>`) and restored.

### Keep the repository tidy

When working here, flag (don't silently fix) anything that breaks these rules: folders missing from the index, index rows with no folder, untracked folders, committed secrets or binaries, skill demos that have outgrown a skill, and demos not verified in over six months. Offer to retire or re-verify stale demos.

## Demo index

Keep this table in sync with the folders. One row per demo.

| Demo | Outcome | Products | Kind | Last verified |
|------|---------|----------|------|---------------|
| [imf-dbt](imf-dbt/) | Turn the IMF World Economic Outlook into governed, documented metrics with dbt running inside Snowflake | dbt Projects on Snowflake, Snowpark Python, external access, tasks, Horizon, semantic views, Cortex Analyst | Project | 2026-10-15 |
