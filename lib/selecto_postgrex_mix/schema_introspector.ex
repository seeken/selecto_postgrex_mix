defmodule SelectoPostgrexMix.SchemaIntrospector do
  @moduledoc """
  Introspects PostgreSQL tables via Postgrex and returns Selecto domain configuration data.

  Unlike SelectoMix.SchemaIntrospector which works with Ecto schemas via `__schema__/1`,
  this module queries the database directly using Postgrex connections.
  """

  alias SelectoPostgrexMix.Introspector.Postgres
  alias SelectoPostgrexMix.Introspector.Expand

  @doc """
  Introspect a table and return Selecto domain configuration data.

  ## Parameters

  - `conn` - Postgrex connection PID
  - `table_name` - Database table name
  - `opts` - Options
    - `:schema` - PostgreSQL schema (default: "public")
    - `:include_associations` - Include FK-based associations (default: true)
    - `:expand` - Include reverse FKs and junction tables (default: false)
    - `:redact_fields` - List of field names to redact
    - `:default_limit` - Default query limit (default: 50)
    - `:include_timestamps` - Include timestamp fields in defaults (default: false)

  ## Returns

  A map containing domain configuration data.
  """
  def introspect_schema(conn, table_name, opts \\ []) do
    pg_schema = Keyword.get(opts, :schema, "public")
    include_associations = Keyword.get(opts, :include_associations, true)
    expand = Keyword.get(opts, :expand, false)
    redact_fields = Keyword.get(opts, :redact_fields, [])

    case Postgres.introspect_table(conn, table_name, schema: pg_schema) do
      {:ok, metadata} ->
        # Optionally expand associations with reverse FKs
        associations =
          if expand and include_associations do
            case Expand.build_expanded_associations(conn, table_name, pg_schema) do
              {:ok, expanded} -> expanded
              {:error, _} -> metadata.associations
            end
          else
            if include_associations, do: metadata.associations, else: %{}
          end

        # Generate suggested defaults
        suggested_defaults =
          generate_suggested_defaults(
            metadata.fields,
            metadata.field_types,
            opts
          )

        # Extract metadata
        extra_metadata = extract_metadata(table_name, metadata)

        %{
          table_name: table_name,
          primary_key: metadata.primary_key,
          fields: metadata.fields,
          field_types: metadata.field_types,
          associations: associations,
          suggested_defaults: suggested_defaults,
          redacted_fields: redact_fields,
          metadata: extra_metadata,
          columns: metadata.columns,
          source: :postgres
        }

      {:error, reason} ->
        %{
          error: "Failed to introspect table #{table_name}: #{inspect(reason)}",
          table_name: table_name
        }
    end
  end

  @doc """
  Extract metadata from table introspection results.
  """
  def extract_metadata(table_name, metadata) do
    module_name = Postgres.table_name_to_module(table_name)

    %{
      module_name: module_name,
      context_name: "Database",
      has_timestamps: has_timestamps?(metadata.fields),
      estimated_complexity: estimate_complexity(metadata)
    }
  end

  # Generate suggested defaults from field metadata
  defp generate_suggested_defaults(fields, field_types, opts) do
    include_timestamps = Keyword.get(opts, :include_timestamps, false)

    %{
      default_selected: suggest_default_selected_fields(fields, field_types, include_timestamps),
      default_filters: suggest_default_filters(fields, field_types),
      default_order: suggest_default_ordering(fields, field_types),
      default_limit: Keyword.get(opts, :default_limit, 50)
    }
  end

  defp suggest_default_selected_fields(fields, field_types, include_timestamps) do
    candidates =
      Enum.filter(fields, fn field ->
        field_str = to_string(field)

        name_field = String.contains?(field_str, ["name", "title", "email", "username"])
        id_field = String.ends_with?(field_str, "_id") or field == :id
        status_field = String.contains?(field_str, ["status", "active", "enabled"])
        timestamp_field = include_timestamps and String.contains?(field_str, ["_at", "date"])

        suitable_type =
          field_types[field] in [:string, :integer, :decimal, :boolean, :date, :utc_datetime]

        (name_field or id_field or status_field or timestamp_field) and suitable_type
      end)

    Enum.take(candidates, 5)
  end

  defp suggest_default_filters(fields, field_types) do
    filter_fields =
      Enum.filter(fields, fn field ->
        field_str = to_string(field)
        field_type = field_types[field]

        boolean_filter = field_type == :boolean
        status_filter = String.contains?(field_str, ["status", "type", "category", "role"])

        date_filter =
          field_type in [:date, :utc_datetime] and
            String.contains?(field_str, ["created", "updated"])

        boolean_filter or status_filter or date_filter
      end)

    Enum.into(filter_fields, %{}, fn field ->
      field_type = field_types[field]
      filter_config = generate_filter_config(field, field_type)
      {to_string(field), filter_config}
    end)
  end

  defp generate_filter_config(field, field_type) do
    base_config = %{
      name: humanize_field_name(field),
      type: field_type
    }

    case field_type do
      :boolean ->
        Map.put(base_config, :default, true)

      type when type in [:date, :utc_datetime] ->
        Map.put(base_config, :operator, "gte")

      _ ->
        base_config
    end
  end

  defp suggest_default_ordering(fields, field_types) do
    order_candidates =
      Enum.filter(fields, fn field ->
        field_str = to_string(field)
        field_type = field_types[field]

        timestamp_field =
          field_type in [:date, :utc_datetime] and
            String.contains?(field_str, ["created", "updated", "published"])

        name_field =
          field_type == :string and
            String.contains?(field_str, ["name", "title"])

        id_field = field == :id

        timestamp_field or name_field or id_field
      end)

    case order_candidates do
      [] -> []
      [first | _] -> [%{"field" => to_string(first), "direction" => "asc"}]
    end
  end

  defp has_timestamps?(fields) do
    Enum.any?(fields, fn field ->
      field_str = to_string(field)
      String.contains?(field_str, ["inserted_at", "updated_at"])
    end)
  end

  defp estimate_complexity(metadata) do
    field_count = length(metadata.fields)
    assoc_count = map_size(metadata.associations)

    cond do
      field_count <= 5 and assoc_count <= 2 -> :simple
      field_count <= 15 and assoc_count <= 5 -> :moderate
      true -> :complex
    end
  end

  defp humanize_field_name(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
