# Teardown

Everything here is irreversible. There is no undrop for a connector, a runtime, a
Postgres instance or a deployment, so `SKILL.md` gates each group and asks first.

Run the five groups in `teardown/SKILL.md` one at a time. They are written to be safe to
re-run: every statement is `IF EXISTS`, so a partial teardown can be finished by going again.

## Order, and why it is not obvious

Two dependency chains catch people.

**The connector and runtime are asynchronous.** `STOP`, `TERMINATE` and `DROP` each
return before the state has settled, and the next statement is rejected with an
"is in `<STATE>ING` status" error. Wait on `SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS`
or `..._RUNTIMES` between every step, not just at the end.

**The Postgres instance, policy and database unwind in that order.** The instance holds
the network policy, and the policy references a network rule that lives inside
`WEO_CDC_DEMO`. Dropping the database first fails, and dropping the policy while the
instance still references it fails too.

`TERMINATE` drains in-flight data. `TERMINATE FORCE` discards it. For a demo either is
fine; prefer the plain form so a teardown mid-snapshot does not look like a fault.

## What is deliberately left standing

**The gen 2 deployment**, unless this skill created it during the run. A pre-existing
deployment is shared with other demos and is marked permanent.

If the skill did create one, drop it. An idle deployment bills around **2.64 credits a
day** with no runtime under it, and nothing in Snowflake will chase you for it: resource
monitors do not cover gen 2 compute pools, and gen 2 objects cannot be added to a budget.
Dropping the runtime is not enough, because the cost sits in the deployment's control
pool.

**`OPENFLOW_GEN2.CONTROL`, `OPENFLOW_CDC_ROLE` and `OPENFLOW_WH`**, all reused rather than
created.

## Local cleanup

```bash
rm -f postgresql-42.7.8.jar config.json
```

**Do not `rm ~/.pgpass`.** It holds credentials for every Postgres server the user connects to,
not just this demo's instance, so deleting the file destroys unrelated logins. Remove only the
line for this instance; `teardown/SKILL.md` has the exact commands, along with clearing the
cached hostname so a stale one cannot misdirect the next provision.

Keep the rest of `~/.cache/openflow-weo-demo/`. It is 5.3 MB and saves a download
next time. It only needs replacing when a new vintage comes out.

## Confirming it is clean

The verification group at the end of teardown should return nothing except the
deployment. If you want to check the money rather than the objects, this is the query that
would have caught an idle deployment earlier:

```sql
SELECT start_time::DATE AS day, service_type, name, SUM(credits_used) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND service_type IN ('OPENFLOW_COMPUTE_SNOWFLAKE', 'POSTGRES_COMPUTE')
GROUP BY 1, 2, 3
ORDER BY day DESC, credits DESC;
```

Account Usage lags by up to a few hours, so run it the next day rather than immediately.
