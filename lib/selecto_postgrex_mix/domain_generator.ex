defmodule SelectoPostgrexMix.DomainGenerator do
  @moduledoc """
  Generates Selecto domain configuration files from Postgrex introspection data.

  Unlike SelectoMix.DomainGenerator which generates code referencing Ecto schemas
  and Repo, this module generates code that uses named Postgrex connections directly.
  """

  @doc """
  Generate a complete Selecto domain file from Postgrex introspection data.
  """
  def generate_domain_file(table_name, config, opts \\ []) do
    module_name = get_domain_module_name(table_name, config, opts)
    overlay_module_name = SelectoPostgrexMix.OverlayGenerator.overlay_module_name(module_name)
    saved_views_use = generate_saved_views_use(opts)
    connection_name = opts[:connection_name] || infer_connection_name(opts)

    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Selecto domain configuration for table "#{table_name}".

      This file was automatically generated from PostgreSQL introspection.

      ## Customization with Overlay Files

      This domain uses an overlay configuration system for customization.
      Instead of editing this file directly, customize the domain by editing:

          lib/*/selecto_domains/overlays/*_overlay.ex

      Your overlay customizations are preserved when you regenerate this file.

      ## Usage

          # Basic usage with named Postgrex connection
          selecto = Selecto.configure(#{module_name}.domain(), #{connection_name})

          # Execute queries
          {:ok, {rows, columns, aliases}} = Selecto.execute(selecto)

      ## Regeneration

      To regenerate this file after schema changes:

          mix selecto_postgrex.gen.domain --table #{table_name}

      Your customizations will be preserved during regeneration (unless --force is used).
      \"\"\"
    #{saved_views_use}
      @doc \"\"\"
      Returns the Selecto domain configuration for "#{table_name}".

      This merges the base domain configuration with any overlay customizations.
      \"\"\"
      def domain do
        base_domain()
        |> Selecto.Config.Overlay.merge(overlay())
      end

      @doc \"\"\"
      Returns the base domain configuration (without overlay customizations).
      \"\"\"
      def base_domain do
        #{generate_domain_map(table_name, config)}
      end

      @doc \"\"\"
      Returns the overlay configuration if available.
      \"\"\"
      def overlay do
        if Code.ensure_loaded?(#{overlay_module_name}) do
          #{overlay_module_name}.overlay()
        else
          %{}
        end
      end

      #{generate_helper_functions(table_name, config, connection_name)}
    end
    """
  end

  @doc """
  Generate the core domain configuration map.
  """
  def generate_domain_map(table_name, config) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    "%{\n      # Generated from table: #{table_name}\n" <>
      "      # Last updated: #{timestamp}\n      \n" <>
      "      source: #{generate_source_config(table_name, config)},\n" <>
      "      schemas: #{generate_schemas_config(config)},\n" <>
      "      name: #{generate_domain_name(table_name, config)},\n      \n" <>
      "      # Default selections (customize as needed)\n" <>
      "      default_selected: #{generate_default_selected(config)},\n      \n" <>
      "      # Suggested filters (add/remove as needed)\n" <>
      "      filters: #{generate_filters_config(config)},\n      \n" <>
      "      # Subfilters for relationship-based filtering\n" <>
      "      subfilters: %{},\n" <>
      "      \n" <>
      "      # Window functions configuration\n" <>
      "      window_functions: %{},\n" <>
      "      \n" <>
      "      # Query pagination settings\n" <>
      "      pagination: #{generate_pagination_config()},\n" <>
      "      \n" <>
      "      # Pivot table configuration\n" <>
      "      pivot: %{},\n      \n" <>
      "      # Join configurations\n" <>
      "      joins: #{generate_joins_config(config)}\n    }"
  end

  # Private generation functions

  defp get_domain_module_name(table_name, config, opts) do
    base_name =
      config[:metadata][:module_name] ||
        SelectoPostgrexMix.Introspector.Postgres.table_name_to_module(table_name)

    app_name = normalize_app_name(opts[:app_name] || "MyApp")
    "#{app_name}.SelectoDomains.#{base_name}Domain"
  end

  defp infer_connection_name(opts) do
    app_name = normalize_app_name(opts[:app_name] || "MyApp")
    "#{app_name}.Database"
  end

  defp generate_source_config(table_name, config) do
    primary_key = config[:primary_key] || :id
    fields = config[:fields] || []
    redacted_fields = config[:redacted_fields] || []
    field_types = config[:field_types] || %{}

    redacted_config =
      "        # Fields to exclude from queries\n" <>
        "        redact_fields: #{inspect(redacted_fields)},\n        \n"

    "%{\n        source_table: \"#{table_name}\",\n" <>
      "        primary_key: #{inspect(primary_key)},\n        \n" <>
      "        # Available fields from table\n" <>
      "        fields: #{inspect(fields)},\n        \n" <>
      redacted_config <>
      "        # Field type definitions\n" <>
      "        columns: #{generate_columns_config(fields, field_types)},\n        \n" <>
      "        # Table associations (from foreign keys)\n" <>
      "        associations: #{generate_source_associations(config)}\n      }"
  end

  defp generate_columns_config(fields, field_types) do
    # Detect polymorphic associations
    polymorphic_assocs = detect_polymorphic_associations(fields, field_types)

    columns_map =
      Enum.into(fields, %{}, fn field ->
        type = Map.get(field_types, field, :string)

        config =
          if type == :map do
            %{type: :jsonb, schema: :stub}
          else
            %{type: type}
          end

        {field, config}
      end)

    # Add polymorphic virtual columns
    polymorphic_columns =
      Enum.into(polymorphic_assocs, %{}, fn assoc ->
        {String.to_atom(assoc.base_name),
         %{
           type: :string,
           join_mode: :polymorphic,
           filter_type: :polymorphic,
           type_field: to_string(assoc.type_field),
           id_field: to_string(assoc.id_field),
           entity_types: assoc.suggested_types,
           display_name: String.capitalize(assoc.base_name)
         }}
      end)

    all_columns = Map.merge(columns_map, polymorphic_columns)

    formatted_columns =
      all_columns
      |> Enum.map(fn {field, type_map} ->
        "          #{inspect(field)} => #{inspect(type_map)}"
      end)
      |> Enum.join(",\n")

    "%{\n#{formatted_columns}\n        }"
  end

  defp generate_columns_config_with_mode(fields, field_types, join_mode, primary_key, assoc_config) do
    case join_mode do
      {mode_type, display_field} when mode_type in [:tag, :star, :lookup] ->
        display_field_atom = String.to_atom(display_field)

        columns_map =
          Enum.into(fields, %{}, fn field ->
            type = Map.get(field_types, field, :string)
            {field, %{type: type}}
          end)

        foreign_key_field =
          case assoc_config do
            %{owner_key: owner_key} -> Atom.to_string(owner_key)
            _ -> nil
          end

        metadata = %{
          join_mode: mode_type,
          id_field: primary_key,
          display_field: display_field_atom,
          prevent_denormalization: true,
          filter_type: :multi_select_id
        }

        metadata =
          if foreign_key_field do
            Map.put(metadata, :group_by_filter, foreign_key_field)
          else
            metadata
          end

        columns_map =
          Map.update!(columns_map, display_field_atom, fn col ->
            Map.merge(col, metadata)
          end)

        columns_map =
          if display_field_atom != primary_key && Map.has_key?(columns_map, primary_key) do
            Map.update!(columns_map, primary_key, fn col ->
              Map.put(col, :hidden, true)
            end)
          else
            columns_map
          end

        formatted_columns =
          columns_map
          |> Enum.map(fn {field, config_map} ->
            comment =
              if field == display_field_atom do
                "# #{mode_type} mode: displays name, filters by ID"
              else
                ""
              end

            comment_line = if comment != "", do: "          #{comment}\n", else: ""
            "#{comment_line}          #{inspect(field)} => #{inspect(config_map)}"
          end)
          |> Enum.join(",\n")

        "%{\n#{formatted_columns}\n        }"

      _ ->
        generate_columns_config(fields, field_types)
    end
  end

  defp generate_source_associations(config) do
    associations = config[:associations] || %{}

    if Enum.empty?(associations) do
      "%{}"
    else
      formatted_assocs =
        associations
        |> Enum.map(fn {assoc_name, assoc_config} ->
          format_association_config(assoc_name, assoc_config)
        end)
        |> Enum.join(",\n        ")

      "%{\n        #{formatted_assocs}\n        }"
    end
  end

  defp format_association_config(assoc_name, assoc_config) do
    assoc_name_key = inspect(assoc_name)
    queryable_name = inspect(resolve_schema_key(assoc_name, assoc_config))
    owner_key = inspect(assoc_config[:owner_key])
    related_key = inspect(assoc_config[:related_key])

    if assoc_config[:join_through] do
      join_through = inspect(assoc_config[:join_through])

      "#{assoc_name_key} => %{\n" <>
        "              queryable: #{queryable_name},\n" <>
        "              field: #{inspect(assoc_name)},\n" <>
        "              owner_key: #{owner_key},\n" <>
        "              related_key: #{related_key},\n" <>
        "              join_through: #{join_through}\n" <>
        "            }"
    else
      "#{assoc_name_key} => %{\n" <>
        "              queryable: #{queryable_name},\n" <>
        "              field: #{inspect(assoc_name)},\n" <>
        "              owner_key: #{owner_key},\n" <>
        "              related_key: #{related_key}\n" <>
        "            }"
    end
  end

  defp generate_schemas_config(config) do
    associations = config[:associations] || %{}
    expand_schemas_list = config[:expand_schemas_list] || []
    expand_all = config[:expand] || false
    expand_modes = config[:expand_modes] || %{}
    conn = config[:conn]
    pg_schema = config[:pg_schema] || "public"

    schema_configs =
      associations
      |> Enum.map(fn {_assoc_name, assoc_config} ->
        related_table = assoc_config[:related_table] || to_string(assoc_config[:queryable])
        schema_name = resolve_schema_key(related_table, assoc_config)

        should_expand = should_expand_schema?(schema_name, related_table, expand_schemas_list, expand_all)
        join_mode = get_join_mode_for_schema(schema_name, expand_modes)

        if should_expand and conn do
          generate_expanded_schema_config(schema_name, related_table, conn, pg_schema, join_mode, assoc_config)
        else
          generate_placeholder_schema_config(schema_name, related_table)
        end
      end)
      |> Enum.join(",\n      ")

    if schema_configs == "" do
      "%{}"
    else
      "%{\n      #{schema_configs}\n    }"
    end
  end

  defp should_expand_schema?(_schema_name, _related_table, _expand_schemas_list, true), do: true

  defp should_expand_schema?(schema_name, related_table, expand_schemas_list, false) do
    schema_name_str = to_string(schema_name)
    related_table_str = to_string(related_table)

    Enum.any?(expand_schemas_list || [], fn expand_name ->
      expand_lower = String.downcase(expand_name)
      schema_lower = String.downcase(schema_name_str)
      table_lower = String.downcase(related_table_str)

      expand_lower == schema_lower ||
        expand_lower == table_lower ||
        String.contains?(expand_lower, schema_lower) ||
        String.contains?(table_lower, expand_lower)
    end)
  end

  defp get_join_mode_for_schema(schema_name, expand_modes) do
    schema_name_str = to_string(schema_name)
    schema_name_lower = String.downcase(schema_name_str)

    Enum.find_value(expand_modes, fn {key, value} ->
      key_lower = String.downcase(key)

      cond do
        key_lower == schema_name_lower -> value
        key_lower == schema_name_lower <> "s" -> value
        key_lower <> "s" == schema_name_lower -> value
        String.ends_with?(key_lower, "ies") && String.replace_suffix(key_lower, "ies", "y") == schema_name_lower -> value
        String.ends_with?(schema_name_lower, "ies") && String.replace_suffix(schema_name_lower, "ies", "y") == key_lower -> value
        true -> nil
      end
    end)
  end

  defp generate_placeholder_schema_config(schema_name, table_name) do
    schema_name_key = inspect(schema_name)

    "#{schema_name_key} => %{\n" <>
      "            # TODO: Expand with --expand or --expand-schemas #{schema_name}\n" <>
      "            source_table: \"#{table_name}\",\n" <>
      "            primary_key: :id,\n" <>
      "            fields: [],\n" <>
      "            redact_fields: [],\n" <>
      "            columns: %{},\n" <>
      "            associations: %{}\n" <>
      "          }"
  end

  defp generate_expanded_schema_config(schema_name, related_table, conn, pg_schema, join_mode, assoc_config) do
    case SelectoPostgrexMix.Introspector.Postgres.introspect_table(conn, related_table, schema: pg_schema) do
      {:ok, schema_config} ->
        fields = schema_config.fields
        field_types = schema_config.field_types
        primary_key = schema_config.primary_key || :id

        columns_config =
          generate_columns_config_with_mode(fields, field_types, join_mode, primary_key, assoc_config)

        mode_comment =
          case join_mode do
            {:tag, _} -> "            # Join mode: tag (many-to-many with ID-based filtering)\n"
            {:star, _} -> "            # Join mode: star (lookup table with ID-based filtering)\n"
            {:lookup, _} -> "            # Join mode: lookup (small reference table)\n"
            _ -> ""
          end

        schema_name_key = inspect(schema_name)

        "#{schema_name_key} => %{\n" <>
          "            # Expanded from table: #{related_table}\n" <>
          mode_comment <>
          "            source_table: \"#{related_table}\",\n" <>
          "            primary_key: #{inspect(primary_key)},\n" <>
          "            fields: #{inspect(fields)},\n" <>
          "            redact_fields: [],\n" <>
          "            columns: #{columns_config},\n" <>
          "            associations: %{}\n" <>
          "          }"

      {:error, _reason} ->
        generate_placeholder_schema_config(schema_name, related_table)
    end
  end

  defp detect_polymorphic_associations(fields, _field_types) do
    type_fields =
      Enum.filter(fields, fn field ->
        field_str = to_string(field)
        String.ends_with?(field_str, "_type")
      end)

    Enum.flat_map(type_fields, fn type_field ->
      type_field_str = to_string(type_field)
      base_name = String.replace_suffix(type_field_str, "_type", "")
      id_field = String.to_atom(base_name <> "_id")

      if id_field in fields do
        [
          %{
            base_name: base_name,
            type_field: type_field,
            id_field: id_field,
            suggested_types: ["Product", "Order", "Customer"]
          }
        ]
      else
        []
      end
    end)
  end

  defp generate_domain_name(table_name, config) do
    base_name = config[:metadata][:module_name] || Macro.camelize(table_name)
    inspect("#{base_name} Domain")
  end

  defp generate_default_selected(config) do
    suggested_defaults = config[:suggested_defaults][:default_selected] || []

    formatted_defaults = suggested_defaults |> Enum.map(&inspect(to_string(&1))) |> Enum.join(", ")

    case suggested_defaults do
      [] -> "[]"
      _ -> "[#{formatted_defaults}]"
    end
  end

  defp generate_filters_config(config) do
    suggested_filters = config[:suggested_defaults][:default_filters] || %{}

    if Enum.empty?(suggested_filters) do
      "%{}"
    else
      formatted_filters =
        suggested_filters
        |> Enum.map(fn {filter_name, filter_config} ->
          "\"#{filter_name}\" => #{inspect(filter_config, pretty: true, width: 60)}"
        end)
        |> Enum.join(",\n      ")

      "%{\n      #{formatted_filters}\n    }"
    end
  end

  defp generate_pagination_config do
    "%{\n" <>
      "        default_limit: 50,\n" <>
      "        max_limit: 1000,\n" <>
      "        cursor_fields: [:id],\n" <>
      "        allow_offset: true,\n" <>
      "        require_limit: false\n" <>
      "      }"
  end

  defp generate_joins_config(config) do
    associations = config[:associations] || %{}

    if Enum.empty?(associations) do
      "%{}"
    else
      formatted_joins =
        associations
        |> Enum.map(fn {join_name, join_config} ->
          format_single_join(join_name, join_config)
        end)
        |> Enum.join(",\n      ")

      "%{\n      #{formatted_joins}\n    }"
    end
  end

  defp format_single_join(join_name, join_config) do
    join_type = inspect(Map.get(join_config, :join_type, :left))
    join_name_str = humanize_name(join_name)
    source_val = inspect(resolve_schema_key(join_name, join_config))
    owner_key = join_config[:owner_key] || :id
    related_key = join_config[:related_key] || :id

    on_clause =
      inspect([%{left: to_string(owner_key), right: to_string(related_key)}])

    is_many_to_many = join_config[:type] == :many_to_many

    base =
      "#{inspect(join_name)} => %{\n" <>
        "              name: \"#{join_name_str}\",\n" <>
        "              type: #{join_type},\n" <>
        "              source: #{source_val},\n" <>
        "              on: #{on_clause}"

    many_to_many_config =
      if is_many_to_many do
        ",\n              join_through: #{inspect(join_config[:join_through])},\n" <>
          "              owner_key: #{inspect(join_config[:owner_key] || :id)},\n" <>
          "              assoc_key: #{inspect(join_config[:related_key] || :id)}"
      else
        ""
      end

    base <> many_to_many_config <> "\n            }"
  end

  defp generate_helper_functions(table_name, _config, connection_name) do
    [
      "@doc \"Create a new Selecto instance configured with this domain.\"",
      "def new(conn, opts \\\\ []) do",
      "  validate = Keyword.get(opts, :validate, Mix.env() in [:dev, :test])",
      "  opts = Keyword.put(opts, :validate, validate)",
      "  ",
      "  Selecto.configure(domain(), conn, opts)",
      "end",
      "",
      "@doc \"Get the table name this domain represents.\"",
      "def table_name, do: \"#{table_name}\"",
      "",
      "@doc \"Get available fields (derived from columns to avoid duplication).\"",
      "def available_fields do",
      "  domain().source.columns |> Map.keys()",
      "end",
      "",
      "@doc \"Common query: get all records with default selection.\"",
      "def all(conn, opts \\\\ []) do",
      "  new(conn, opts)",
      "  |> Selecto.select(domain().default_selected)",
      "  |> Selecto.execute()",
      "end",
      "",
      "@doc \"Common query: find by primary key.\"",
      "def find(conn, id, opts \\\\ []) do",
      "  primary_key = domain().source.primary_key",
      "  ",
      "  new(conn, opts)",
      "  |> Selecto.select(domain().default_selected)",
      "  |> Selecto.filter({to_string(primary_key), id})",
      "  |> Selecto.execute_one()",
      "end",
      "",
      "@doc \"\"\"",
      "Get the default connection name for this domain.",
      "",
      "Add this to your application supervision tree:",
      "",
      "    children = [",
      "      {Postgrex, name: #{connection_name}, hostname: \"localhost\", database: \"mydb\", ...}",
      "    ]",
      "\"\"\"",
      "def connection_name, do: #{connection_name}"
    ]
    |> Enum.join("\n    ")
  end

  defp generate_saved_views_use(opts) do
    if opts[:saved_views] do
      app_name = normalize_app_name(opts[:app_name] || "MyApp")
      saved_view_context = "#{app_name}.SavedViewContext"
      "\n      use #{saved_view_context}\n"
    else
      ""
    end
  end

  defp resolve_schema_key(default_name, assoc_config) when is_map(assoc_config) do
    case assoc_config[:related_module_name] do
      module_name when is_binary(module_name) ->
        module_name |> Macro.underscore() |> String.to_atom()

      module_name when is_atom(module_name) ->
        module_name |> to_string() |> Macro.underscore() |> String.to_atom()

      _ ->
        default_name |> to_string() |> String.to_atom()
    end
  end

  defp normalize_app_name(app_name) when is_atom(app_name) do
    app_name
    |> Atom.to_string()
    |> Macro.camelize()
  end

  defp normalize_app_name(app_name) when is_binary(app_name) do
    if String.contains?(app_name, ".") do
      app_name
    else
      Macro.camelize(app_name)
    end
  end

  defp normalize_app_name(app_name), do: app_name |> to_string() |> Macro.camelize()

  defp humanize_name(atom) when is_atom(atom) do
    atom
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp humanize_name(str) when is_binary(str) do
    str
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
