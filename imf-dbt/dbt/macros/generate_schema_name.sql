{#
    Without this macro dbt concatenates the profile schema and the custom schema
    using its own casing, so +schema: bronze lands in DEV_bronze rather than
    DEV_BRONZE. Snowflake then quotes the mixed case and you end up needing quotes
    to query your own tables. Everyone hits this once.

    What we want, driven by DBT_CURRENT_SCHEMA in env.yml:

      dev  -> DEV_BRONZE,  DEV_SILVER,  DEV_GOLD,  DEV_SNAPSHOTS
      prod -> PROD_BRONZE, PROD_SILVER, PROD_GOLD, PROD_SNAPSHOTS

    RAW is deliberately absent from this, because dbt never writes there. It holds
    landed data shared across environments and is declared as a source, not a model.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema | upper -%}

    {%- if custom_schema_name is none -%}
        {{ default_schema }}

    {%- else -%}
        {{ default_schema }}_{{ custom_schema_name | trim | upper }}

    {%- endif -%}

{%- endmacro %}
