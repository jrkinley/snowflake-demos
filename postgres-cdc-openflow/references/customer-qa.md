# Customer questions about gen 2

Background for questions engineers ask during or after the demo. None of this is a failure.

## Gen 2 objects are invisible to the tooling you would reach for

Worth knowing before a customer finds it:

- Absent from `ACCESS_HISTORY`, `OBJECT_DEPENDENCIES` and Snowsight lineage.
- Resource monitors do not cover gen 2 compute pools, and gen 2 objects cannot be added to
  a budget, so nothing catches a forgotten deployment.
- No `CLONE`, `CREATE OR REPLACE`, `CREATE OR ALTER`, object tagging, sharing or DCM
  support. No replication or failover group, so no built-in cross-region DR.
- Avoid `GRANT OWNERSHIP` on a runtime. It is accepted in SQL and can break control-plane
  bindings.

One improvement worth quoting the other way: `USAGE` on a deployment does **not** grant
visibility of its runtimes, and a user needs a privilege on a deployment even to see it
listed. That makes multi-team isolation enforceable rather than a matter of trust.

## Telemetry is per deployment, not per runtime

`RESOURCE_ATTRIBUTES` in the event table has `snow.openflow.deployment.id` but no runtime name,
so a deployment shared between runtimes gives mixed logs. The runtime id is inside the log
record, at `mdc.openflow.runtime.id`. Event table rows are JSON strings, so parse before
extracting. `<event_table>` is the account's active event table, from
`SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT`:

```sql
SELECT TRY_PARSE_JSON(TO_VARCHAR(VALUE)):formattedMessage::STRING AS message
FROM <event_table>
WHERE ...;
```

## Snowsight cannot GET or PUT on the connector stage

Connector stages are not supported in the Snowsight stage UI. Use `PUT` and `GET` through SQL.

## The connector canvas is read-only

Inspecting a component returns "the Connector must be in Troubleshooting mode". Troubleshooting
mode is a toggle in the Openflow UI, not a SQL command. The event table covers most diagnosis.
