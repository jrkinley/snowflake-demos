{#
    Runs once at the end of every dbt invocation (on-run-end in dbt_project.yml).

    store_failures keeps the failing rows of each test, but it replaces those
    tables on every run, so on its own it only ever shows the latest failures.
    This macro adds the missing history: one row per test per run in
    <ENV>_AUDIT.TEST_RESULTS_HISTORY, which is created on first use and only
    ever appended to.

    It also re-attaches the Snowflake data metric function on the hyperinflation
    audit table. store_failures recreates that table each run, and a recreated
    table loses its DMF associations, so the attachment has to follow the rebuild.
#}
{% macro record_test_results(results) %}
    {% if not execute %}{{ return('') }}{% endif %}

    {% set tests = [] %}
    {% for r in results if r.node.resource_type == 'test' %}
        {% do tests.append(r) %}
    {% endfor %}
    {% if tests | length == 0 %}{{ return('') }}{% endif %}

    {% set audit_schema = target.database ~ '.' ~ generate_schema_name('audit', none) %}
    {% set history = audit_schema ~ '.TEST_RESULTS_HISTORY' %}

    {% do run_query('create schema if not exists ' ~ audit_schema) %}
    {% do run_query('
        create table if not exists ' ~ history ~ ' (
            invocation_id       varchar   comment \'dbt invocation id, one per run\',
            run_started_at      timestamp_ntz comment \'When the dbt run started (UTC)\',
            target_name         varchar   comment \'dbt target, for example dev or prod\',
            test_unique_id      varchar   comment \'dbt unique id of the test\',
            test_name           varchar   comment \'Test name\',
            severity            varchar   comment \'error or warn\',
            status              varchar   comment \'pass, warn, fail, error or skipped\',
            failures            integer   comment \'Number of rows the test returned\',
            execution_time_s    float     comment \'Test run time in seconds\',
            audit_relation      varchar   comment \'Table holding the failing rows, when stored\'
        )
        comment = \'History of every dbt test result, one row per test per run. Appended by the record_test_results on-run-end hook.\'
    ') %}

    {% set rows = [] %}
    {% for r in tests %}
        {% set row %}
            ('{{ invocation_id }}',
             '{{ run_started_at.strftime("%Y-%m-%d %H:%M:%S") }}'::timestamp_ntz,
             '{{ target.name }}',
             '{{ r.node.unique_id }}',
             '{{ r.node.name }}',
             '{{ r.node.config.severity | lower }}',
             '{{ r.status }}',
             {{ r.failures if r.failures is not none else 'null' }},
             {{ r.execution_time | round(3) }},
             {{ "'" ~ r.node.relation_name | replace('"', '') ~ "'" if r.node.relation_name else 'null' }})
        {% endset %}
        {% do rows.append(row) %}
    {% endfor %}
    {% do run_query('insert into ' ~ history ~ ' values ' ~ rows | join(',')) %}

    {% set hyper = audit_schema ~ '.WARN_HYPERINFLATION_SINCE_2020' %}
    {% set found = run_query(
        "select count(*) from " ~ target.database ~ ".information_schema.tables "
        ~ "where table_schema = '" ~ generate_schema_name('audit', none) ~ "' "
        ~ "and table_name = 'WARN_HYPERINFLATION_SINCE_2020'"
    ) %}
    {% if found.columns[0].values()[0] > 0 %}
        {#- A timed schedule, not TRIGGER_ON_CHANGES. The table is written once by
            store_failures before this hook attaches the DMF, and never changes
            again, so a change trigger would never fire. -#}
        {% do run_query("alter table " ~ hyper ~ " set data_metric_schedule = '5 MINUTE'") %}
        {% do run_query(
            "alter table " ~ hyper ~ " add data metric function snowflake.core.row_count on () "
            ~ "expectation no_hyperinflation (value = 0)"
        ) %}
    {% endif %}

    {{ return('') }}
{% endmacro %}
