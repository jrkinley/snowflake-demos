{#
    Runs once at the end of every dbt invocation (on-run-end in dbt_project.yml).

    store_failures keeps the failing rows of each test, but it replaces those
    tables on every run, so on its own it only ever shows the latest failures.
    This macro adds the missing history: one row per test per run in
    <ENV>_AUDIT.TEST_RESULTS_HISTORY, which is created on first use and only
    ever appended to.

    It also makes sure the history is monitored by a Snowflake data metric
    function, so a test that stops passing shows up as a violated expectation
    in Snowflake data quality monitoring.
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

    {#- Monitor the history with a Snowflake data metric function. The history
        table is only ever appended to, so unlike the per-test audit tables it
        keeps its DMF binding and its measurement history between runs. The
        function counts tests that did not pass in the latest run, so any value
        above zero violates the expectation. Both the function and the binding
        are created once and left alone after that.

        Not WITHIN GROUP (test_name): Snowflake accepts that binding but then
        suspends it as invalid, without an error, because of the subquery that
        finds the latest run. The per-test detail is in the history table. -#}
    {% set dmf = audit_schema ~ '.FAILING_TESTS_LATEST_RUN' %}
    {% do run_query("
        create data metric function if not exists " ~ dmf ~ " (
            t table(run_started_at timestamp_ntz, status varchar)
        )
        returns number
        comment = 'Tests that did not pass in the latest dbt run'
        as
        $$
            select count_if(status in ('warn', 'fail', 'error'))
            from t
            where run_started_at = (select max(run_started_at) from t)
        $$
    ") %}

    {% set bound = run_query(
        "select count(*) from table(" ~ target.database ~ ".information_schema.data_metric_function_references("
        ~ "ref_entity_name => '" ~ history ~ "', ref_entity_domain => 'TABLE'))"
        ~ " where metric_name = 'FAILING_TESTS_LATEST_RUN'"
    ) %}
    {% if bound.columns[0].values()[0] == 0 %}
        {#- TRIGGER_ON_CHANGES works here because every run inserts into the
            history after the binding exists, so each run is measured at once. -#}
        {% do run_query("alter table " ~ history ~ " set data_metric_schedule = 'TRIGGER_ON_CHANGES'") %}
        {% do run_query(
            "alter table " ~ history ~ " add data metric function " ~ dmf
            ~ " on (run_started_at, status)"
            ~ " expectation all_tests_pass (value = 0)"
        ) %}
    {% endif %}

    {{ return('') }}
{% endmacro %}
