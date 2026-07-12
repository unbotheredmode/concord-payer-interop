{# 
  Override dbt's default schema name generation.
  Default behavior: target_schema + "_" + custom_schema = "STAGING_STAGING" (wrong)
  This macro: use custom_schema exactly as declared in dbt_project.yml
  
  Result:
    models/staging/ → CONCORD.STAGING
    models/marts/   → CONCORD.MARTS
#}

{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}