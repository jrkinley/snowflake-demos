#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Create the demo Postgres instance and capture its password without showing it.

This script exists for one reason. CREATE POSTGRES INSTANCE returns the
snowflake_admin password once, in the access_roles column, and DESCRIBE will not
give it back. Running that statement any way that displays its output puts the
credential on screen and into the session transcript, which is unacceptable for
a skill whose whole point is being screen-shared. So the statement runs here, the
result is parsed, and the password goes straight to ~/.pgpass and a Snowflake
secret. Nothing sensitive is printed.

Everything else in provisioning is plain SQL run from markdown. Only this one
statement needs code.

Idempotent. If the instance already exists the CREATE returns no password, so it
is recovered from ~/.pgpass. If that is missing too, the password is gone for
good and the instance has to be recreated.

Prerequisite: the database, schema, ingress rule and network policy already
exist. Run sql/01-postgres-prereqs.sql with `snow sql -f` first, which is safe
because nothing in it returns a secret.

Usage:
    create-postgres-instance.py -c CONNECTION [--instance NAME] [--secret NAME]
"""

import argparse
import json
import stat
import subprocess
import sys
import time
from pathlib import Path

PG_USER = "snowflake_admin"
HOST_CACHE = Path.home() / ".cache" / "openflow-weo-demo" / "pg-host"


def run_sql(connection, statement):
    """Run one statement, returning parsed rows. Never echoes the statement back
    on failure, since it may carry a substituted secret."""
    result = subprocess.run(
        ["snow", "sql", "-c", connection, "-q", statement, "--format", "json"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"snow sql failed ({result.returncode}): {result.stderr.strip()[:400]}")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []
    rows = []
    for item in payload if isinstance(payload, list) else [payload]:
        rows.extend(item) if isinstance(item, list) else rows.append(item)
    return rows


def write_pgpass(host, password):
    path = Path.home() / ".pgpass"
    line = f"{host}:5432:*:{PG_USER}:{password}"
    kept = [
        existing for existing in
        (path.read_text().splitlines() if path.exists() else [])
        if existing.strip() and not existing.startswith(f"{host}:")
    ]
    path.write_text("\n".join(kept + [line]) + "\n")
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)
    return path


def password_from_pgpass(host):
    path = Path.home() / ".pgpass"
    if not path.exists():
        return None
    for line in path.read_text().splitlines():
        parts = line.split(":")
        if len(parts) >= 5 and parts[0] == host and parts[3] == PG_USER:
            return ":".join(parts[4:])
    return None


def describe(connection, instance):
    """property -> value from DESCRIBE POSTGRES INSTANCE."""
    rows = run_sql(connection, f"DESCRIBE POSTGRES INSTANCE {instance}")
    return {str(r.get("property", "")).lower(): r.get("value") for r in rows}


def wait_for_ready(connection, instance, timeout=600):
    """Poll to READY. The CREATE returns in seconds but the instance is not
    usable for another two to three minutes, through CREATING and FINALIZING.
    Waiting here rather than printing a command to run keeps it one step."""
    deadline = time.monotonic() + timeout
    seen = None
    started = time.monotonic()
    while time.monotonic() < deadline:
        state = (describe(connection, instance).get("state") or "").upper()
        if state != seen:
            print(f"  state {state}")
            seen = state
        if state == "READY":
            print(f"  ready after {int(time.monotonic() - started)}s")
            return True
        if state in {"FAILED", "SUSPENDED"}:
            sys.exit(f"instance reached {state}; not usable")
        time.sleep(10)
    sys.exit(f"timed out after {timeout}s waiting for READY")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-c", "--connection", required=True)
    parser.add_argument("--instance", default="WEO_CDC_PG")
    parser.add_argument("--policy", default="WEO_CDC_PG_POLICY")
    parser.add_argument("--secret", default="WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_PASSWORD")
    parser.add_argument("--no-wait", action="store_true",
                        help="return as soon as the CREATE does, without polling to READY")
    args = parser.parse_args()

    print(f"creating postgres instance {args.instance}")
    rows = run_sql(args.connection, (
        "USE ROLE ACCOUNTADMIN; "
        f"CREATE POSTGRES INSTANCE IF NOT EXISTS {args.instance} "
        "COMPUTE_FAMILY = 'BURST_S' STORAGE_SIZE_GB = 10 "
        "AUTHENTICATION_AUTHORITY = POSTGRES POSTGRES_VERSION = 17 "
        f"NETWORK_POLICY = '{args.policy}' "
        "COMMENT = 'Source for the Openflow gen 2 CDC demo. Safe to drop with the demo.'"
    ))

    host = password = None
    for row in rows:
        for key, value in row.items():
            if key.lower() == "host" and value:
                host = value
            if key.lower() == "access_roles" and value:
                try:
                    password = json.loads(value).get(PG_USER)
                except (json.JSONDecodeError, AttributeError):
                    pass

    if host is None:
        host = describe(args.connection, args.instance).get("host")
    if not host:
        sys.exit("could not determine the instance host")
    print(f"  host {host}")

    if password:
        print(f"  password written to {write_pgpass(host, password)} (mode 600), not shown")
    else:
        password = password_from_pgpass(host)
        if password:
            print("  instance already existed; recovered the password from ~/.pgpass")
        else:
            sys.exit(
                "  instance already existed and ~/.pgpass has no entry for it.\n"
                "  Snowflake issues the password once, so it cannot be recovered.\n"
                "  Drop and recreate the instance."
            )

    run_sql(args.connection, (
        f"USE ROLE ACCOUNTADMIN; CREATE OR REPLACE SECRET {args.secret} "
        f"TYPE = GENERIC_STRING SECRET_STRING = '{password}'"
    ))
    print(f"  password stored in secret {args.secret}")

    if not args.no_wait:
        wait_for_ready(args.connection, args.instance)

    # Every later step needs the host: the egress network rule, the JDBC URL and
    # both psql calls. Emit it as a paste-ready export and cache it, so nobody
    # retypes a 60-character hostname into a network rule.
    HOST_CACHE.parent.mkdir(parents=True, exist_ok=True)
    HOST_CACHE.write_text(host + "\n")
    print(f"\nexport PG_HOST={host}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
