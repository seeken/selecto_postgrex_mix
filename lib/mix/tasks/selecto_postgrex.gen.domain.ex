defmodule Mix.Tasks.SelectoPostgrex.Gen.Domain do
  @shortdoc "Generate Selecto domain configuration from PostgreSQL tables"
  @moduledoc """
  Generate Selecto domain configuration from PostgreSQL tables using direct
  Postgrex introspection (no Ecto schemas required).

  ## Examples

      # Generate domain for a single table
      mix selecto_postgrex.gen.domain --table products

      # Generate with DATABASE_URL
      DATABASE_URL="postgres://user:pass@localhost/mydb" \\
        mix selecto_postgrex.gen.domain --table products --expand --live

      # Generate for all tables
      mix selecto_postgrex.gen.domain --all

      # Explicit connection parameters
      mix selecto_postgrex.gen.domain --table products \\
        --database mydb --host localhost --username postgres

  ## Options

    * `--table` - Table name to generate domain for (required unless --all)
    * `--all` - Generate domains for all tables in the database
    * `--exclude` - Comma-separated list of tables to exclude
    * `--database-url` - PostgreSQL connection URL
    * `--host` - Database hostname (default: localhost)
    * `--port` - Database port (default: 5432)
    * `--database` - Database name
    * `--username` - Database username
    * `--password` - Database password
    * `--connection-name` - Named Postgrex connection for generated code (default: AppName.Database)
    * `--schema` - PostgreSQL schema to introspect (default: public)
    * `--include-associations` - Include FK associations as joins (default: true)
    * `--expand` - Include reverse FK associations (has_many, many_to_many)
    * `--expand-schemas` - Comma-separated list of related tables to fully expand
    * `--expand-tag` - Tag mode: TableName:display_field
    * `--expand-star` - Star schema mode: TableName:display_field
    * `--expand-lookup` - Lookup mode: TableName:display_field
    * `--expand-polymorphic` - Polymorphic association: field_name:type_field,id_field:Type1,Type2,Type3
    * `--parameterized-joins` - Add guidance notice for parameterized joins workflow
    * `--live` - Generate LiveView files
    * `--saved-views` - Generate saved views support (requires --live)
    * `--path` - Custom route path for LiveView
    * `--output` - Output directory
    * `--force` - Overwrite existing files
    * `--dry-run` - Show what would be generated
    * `--enable-modal` - Enable modal detail view in LiveView

  ## File Generation

  For each table, generates:
  - `selecto_domains/TABLE_domain.ex` - Selecto domain configuration
  - `selecto_domains/overlays/TABLE_domain_overlay.ex` - Overlay for customization

  With `--live` flag, additionally generates:
  - `live/TABLE_live.ex` - LiveView module
  """

  use Igniter.Mix.Task

  alias SelectoPostgrexMix.Connection

  alias SelectoMix.{
    ConnectionOpts,
    ConfigMerger,
    DomainGenerator,
    LiveViewGenerator,
    OverlayGenerator,
    SchemaIntrospector
  }

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :selecto,
      example: "mix selecto_postgrex.gen.domain --table products --expand --live",
      positional: [],
      schema:
        [
          table: :string,
          all: :boolean,
          exclude: :string,
          output: :string,
          force: :boolean,
          dry_run: :boolean,
          include_associations: :boolean,
          live: :boolean,
          saved_views: :boolean,
          expand: :boolean,
          expand_schemas: :string,
          expand_tag: :keep,
          expand_star: :keep,
          expand_lookup: :keep,
          expand_polymorphic: :keep,
          parameterized_joins: :boolean,
          path: :string,
          enable_modal: :boolean
        ] ++ ConnectionOpts.connection_schema(),
      aliases:
        [
          t: :table,
          a: :all,
          x: :exclude,
          o: :output,
          f: :force,
          d: :dry_run,
          l: :live,
          s: :saved_views,
          e: :expand
        ] ++ ConnectionOpts.connection_aliases()
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    options = igniter.args.options
    parsed_args = Map.new(options) |> Map.put_new(:include_associations, true)

    igniter =
      Igniter.add_notice(
        igniter,
        "selecto_postgrex.gen.domain is on the consolidation path; equivalent shared command: #{equivalent_selecto_mix_command(parsed_args)}"
      )

    case delegate_to_selecto_mix(parsed_args) do
      :ok ->
        igniter

      {:error, output} ->
        IO.puts(output)

        igniter =
          Igniter.add_warning(
            igniter,
            "Shared selecto.gen.domain delegation failed; falling back to legacy selecto_postgrex generation"
          )

        # Parse expand modes
        expand_modes = parse_expand_modes(parsed_args)
        expand_schemas = parse_expand_schemas(parsed_args[:expand_schemas] || "")
        schemas_from_modes = Map.keys(expand_modes)
        expand_schemas = Enum.uniq(expand_schemas ++ schemas_from_modes)

        # Validate flags
        igniter = validate_flags(igniter, parsed_args)

        conn_opts = ConnectionOpts.from_parsed_args(parsed_args)
        pg_schema = parsed_args[:schema] || "public"
        exclude_patterns = parse_exclude_patterns(parsed_args[:exclude] || "")

        tables =
          cond do
            parsed_args[:all] ->
              discover_all_tables(conn_opts, pg_schema)

            table = parsed_args[:table] ->
              [table]

            true ->
              []
          end

        tables = Enum.reject(tables, &table_matches_exclude?(&1, exclude_patterns))

        if Enum.empty?(tables) do
          Igniter.add_warning(igniter, """
          No tables specified. Use one of:
            mix selecto_postgrex.gen.domain --table TABLE_NAME
            mix selecto_postgrex.gen.domain --all
          """)
        else
          updated_args =
            parsed_args
            |> Map.put(:expand_schemas_list, expand_schemas)
            |> Map.put(:expand_modes, expand_modes)
            |> Map.put(:conn_opts, conn_opts)
            |> Map.put(:pg_schema, pg_schema)

          process_tables(igniter, tables, updated_args)
        end
    end
  end

  # Private functions

  defp validate_flags(igniter, parsed_args) do
    cond do
      parsed_args[:saved_views] && !parsed_args[:live] ->
        Igniter.add_warning(igniter, "--saved-views flag requires --live flag to be set")

      true ->
        igniter
    end
  end

  defp discover_all_tables(conn_opts, pg_schema) do
    case Connection.with_connection(conn_opts, fn conn ->
           postgresql_adapter().list_tables(conn, schema: pg_schema)
         end) do
      {:ok, tables} ->
        Enum.reject(tables, &(&1 in ConnectionOpts.system_tables()))

      {:error, reason} ->
        Mix.shell().error("Failed to list tables: #{inspect(reason)}")
        []
    end
  end

  defp parse_expand_schemas(expand_arg) when is_list(expand_arg) do
    expand_arg
    |> Enum.flat_map(fn item ->
      item
      |> String.split(",")
      |> Enum.map(&String.trim/1)
    end)
    |> Enum.filter(&(&1 != ""))
  end

  defp parse_expand_schemas(expand_arg) when is_binary(expand_arg) do
    expand_arg
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp parse_expand_schemas(_), do: []

  defp parse_exclude_patterns(exclude_arg) when is_binary(exclude_arg) do
    exclude_arg
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_exclude_patterns(_), do: []

  defp table_matches_exclude?(table_name, exclude_patterns) do
    table_name = String.downcase(to_string(table_name))

    Enum.any?(exclude_patterns, fn pattern ->
      String.contains?(table_name, String.downcase(pattern))
    end)
  end

  defp parse_expand_modes(parsed_args) do
    modes = [:expand_tag, :expand_star, :expand_lookup, :expand_polymorphic]

    Enum.reduce(modes, %{}, fn mode, acc ->
      mode_type = mode |> to_string() |> String.replace("expand_", "") |> String.to_atom()

      case Map.get(parsed_args, mode) do
        nil ->
          acc

        specs when is_list(specs) ->
          Enum.reduce(specs, acc, fn spec, mode_acc ->
            parse_expand_mode_spec(spec, mode_type, mode_acc)
          end)

        spec when is_binary(spec) ->
          parse_expand_mode_spec(spec, mode_type, acc)

        _ ->
          acc
      end
    end)
  end

  defp parse_expand_mode_spec(spec, mode_type, acc) do
    cond do
      mode_type == :polymorphic ->
        case String.split(spec, ":") do
          [field_name, fields, types] ->
            case String.split(fields, ",") do
              [type_field, id_field] ->
                entity_types = String.split(types, ",") |> Enum.map(&String.trim/1)

                poly_config = %{
                  field_name: String.trim(field_name),
                  type_field: String.trim(type_field),
                  id_field: String.trim(id_field),
                  entity_types: entity_types
                }

                Map.put(acc, String.trim(field_name), {:polymorphic, poly_config})

              _ ->
                acc
            end

          _ ->
            acc
        end

      true ->
        case String.split(spec, ":") do
          [table_name, display_field] ->
            Map.put(acc, String.trim(table_name), {mode_type, String.trim(display_field)})

          _ ->
            acc
        end
    end
  end

  defp process_tables(igniter, tables, opts) do
    output_dir = get_output_directory(igniter, opts[:output])

    if opts[:dry_run] do
      show_dry_run_summary(tables, output_dir, opts)
      igniter
    else
      # Generate saved views implementation first if requested
      igniter =
        if opts[:saved_views] do
          generate_saved_views_if_needed(igniter, opts)
        else
          igniter
        end

      igniter =
        if opts[:parameterized_joins] do
          Igniter.add_notice(
            igniter,
            "Parameterized joins enabled: use mix selecto.gen.parameterized_join to scaffold join templates"
          )
        else
          igniter
        end

      Enum.reduce(tables, igniter, fn table, acc_igniter ->
        generate_domain_for_table(acc_igniter, table, output_dir, opts)
      end)
    end
  end

  defp get_output_directory(igniter, custom_output) do
    case custom_output do
      nil ->
        app_name = Igniter.Project.Application.app_name(igniter)
        "lib/#{app_name}/selecto_domains"

      custom ->
        custom
    end
  end

  defp show_dry_run_summary(tables, output_dir, opts) do
    IO.puts("""

    SelectoPostgrex Domain Generation (DRY RUN)
    ============================================

    Output directory: #{output_dir}
    Include associations: #{Map.get(opts, :include_associations, true)}
    Expand associations: #{opts[:expand] || false}
    Force overwrite: #{opts[:force] || false}
    Generate LiveView: #{opts[:live] || false}
    Generate Saved Views: #{opts[:saved_views] || false}
    Parameterized joins hint: #{opts[:parameterized_joins] || false}

    Tables to process:
    """)

    Enum.each(tables, fn table ->
      domain_file = domain_file_path(output_dir, table)
      IO.puts("  * #{table}")
      IO.puts("    -> #{domain_file}")
    end)

    IO.puts("\nRun without --dry-run to generate files.")
  end

  defp generate_domain_for_table(igniter, table, output_dir, opts) do
    domain_file = domain_file_path(output_dir, table)
    conn_opts = opts[:conn_opts] || []
    pg_schema = opts[:pg_schema] || "public"

    igniter_with_domain =
      igniter
      |> ensure_directory_exists(output_dir)
      |> remove_legacy_duplicate_files(table, output_dir, domain_file)
      |> generate_domain_file(table, domain_file, conn_opts, pg_schema, opts)
      |> generate_overlay_file(table, domain_file, conn_opts, pg_schema, opts)
      |> add_connection_setup_notice(opts)

    if opts[:live] do
      generate_live_view_for_table(igniter_with_domain, table, opts)
    else
      igniter_with_domain
    end
  end

  defp domain_file_path(output_dir, table) do
    filename = Macro.underscore(table)
    Path.join([output_dir, "#{filename}_domain.ex"])
  end

  defp remove_legacy_duplicate_files(igniter, table, output_dir, current_domain_file) do
    legacy_basename =
      table
      |> LiveViewGenerator.source_live_name()
      |> Macro.underscore()

    legacy_domain_file = Path.join([output_dir, "#{legacy_basename}_domain.ex"])

    igniter =
      if legacy_domain_file != current_domain_file and File.exists?(legacy_domain_file) do
        File.rm!(legacy_domain_file)
        igniter
      else
        igniter
      end

    current_overlay_file = OverlayGenerator.overlay_file_path(current_domain_file)
    legacy_overlay_file = OverlayGenerator.overlay_file_path(legacy_domain_file)

    if legacy_overlay_file != current_overlay_file and File.exists?(legacy_overlay_file) do
      File.rm!(legacy_overlay_file)
      igniter
    else
      igniter
    end
  end

  defp ensure_directory_exists(igniter, dir_path) do
    gitkeep_path = Path.join(dir_path, ".gitkeep")

    if File.exists?(gitkeep_path) do
      igniter
    else
      Igniter.create_new_file(igniter, gitkeep_path, "")
    end
  end

  defp generate_domain_file(igniter, table, file_path, conn_opts, pg_schema, opts) do
    existing_content = read_existing_file(file_path)
    app_name = get_app_name(igniter) |> to_string() |> Macro.camelize()
    gen_opts = opts |> Map.put(:app_name, app_name) |> Map.to_list()

    content =
      Connection.with_connection(conn_opts, fn conn ->
        config = introspect_shared_domain_config(conn, table, pg_schema, opts)

        merged_config =
          if opts[:force] do
            config
          else
            ConfigMerger.merge_with_existing(config, existing_content)
          end

        source = {:db, SelectoDBPostgreSQL.Adapter, conn, table, schema: pg_schema}
        DomainGenerator.generate_domain_file(source, merged_config, gen_opts)
      end)

    if File.exists?(file_path) do
      File.rm!(file_path)
    end

    Igniter.create_new_file(igniter, file_path, content)
  end

  defp generate_overlay_file(igniter, table, domain_file_path, conn_opts, pg_schema, opts) do
    overlay_path = OverlayGenerator.overlay_file_path(domain_file_path)

    if File.exists?(overlay_path) do
      igniter
    else
      config =
        Connection.with_connection(conn_opts, fn conn ->
          introspect_shared_domain_config(conn, table, pg_schema, opts)
        end)

      app_name = get_app_name(igniter) |> to_string() |> Macro.camelize()
      source = {:db, SelectoDBPostgreSQL.Adapter, :fallback_conn, table, schema: pg_schema}
      domain_module_name = DomainGenerator.domain_module_name(source, config, app_name: app_name)

      content = OverlayGenerator.generate_overlay_file(domain_module_name, config, opts)

      overlay_dir = Path.dirname(overlay_path)

      igniter
      |> ensure_directory_exists(overlay_dir)
      |> Igniter.create_new_file(overlay_path, content)
    end
  end

  defp generate_live_view_for_table(igniter, table, opts) do
    app_name = get_app_name(igniter) |> to_string() |> Macro.camelize()
    pg_schema = opts[:pg_schema] || "public"
    source = {:db, SelectoDBPostgreSQL.Adapter, :fallback_conn, table, schema: pg_schema}

    live_file = LiveViewGenerator.live_view_file_path(app_name, source)
    html_file = LiveViewGenerator.live_view_html_file_path(app_name, source)
    live_dir = Path.dirname(live_file)
    schema_name = LiveViewGenerator.source_live_name(source)
    domain_module = "#{app_name}.SelectoDomains.#{schema_name}Domain"
    template_opts = Map.to_list(opts)

    live_content =
      LiveViewGenerator.render_live_view_template(
        app_name,
        source,
        domain_module,
        template_opts,
        get_selecto_components_location()
      )

    html_content = LiveViewGenerator.render_live_view_html_template(source, template_opts)

    igniter
    |> ensure_directory_exists(live_dir)
    |> Igniter.create_new_file(live_file, live_content)
    |> Igniter.create_new_file(html_file, html_content)
    |> Igniter.add_notice(LiveViewGenerator.route_suggestion(source, template_opts))
  end

  defp add_connection_setup_notice(igniter, opts) do
    connection_name = opts[:connection_name] || "AppName.Database"

    Igniter.add_notice(igniter, """

    Ensure your Postgrex connection is in your supervision tree:

        children = [
          {Postgrex,
           name: #{connection_name},
           hostname: "localhost",
           database: "mydb",
           username: "postgres",
           password: "postgres"}
        ]
    """)
  end

  defp generate_saved_views_if_needed(igniter, _opts) do
    app_name = get_app_name(igniter)
    app_name_string = Macro.camelize(to_string(app_name))

    saved_view_context_path = "lib/#{app_name}/saved_view_context.ex"

    if File.exists?(saved_view_context_path) do
      igniter
    else
      IO.puts("\nGenerating SavedViews implementation...")

      case System.cmd(
             "mix",
             ["selecto.gen.saved_views", app_name_string, "--adapter", "postgresql", "--yes"],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          IO.puts(output)
          igniter

        {output, _exit_code} ->
          IO.puts(output)

          Igniter.add_warning(igniter, """
          Failed to auto-generate saved views. Please run manually:

              mix selecto.gen.saved_views #{app_name_string} --adapter postgresql
          """)
      end
    end
  end

  defp read_existing_file(file_path) do
    case File.read(file_path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp get_app_name(igniter) do
    Igniter.Project.Application.app_name(igniter)
  end

  defp get_selecto_components_location() do
    vendor_path = Path.join([File.cwd!(), "vendor", "selecto_components"])

    if File.dir?(vendor_path) do
      "vendor"
    else
      "deps"
    end
  end

  defp postgresql_adapter do
    Module.concat(["SelectoDBPostgreSQL", "Adapter"])
  end

  defp introspect_shared_domain_config(conn, table, pg_schema, opts) do
    source = {:db, SelectoDBPostgreSQL.Adapter, conn, table, schema: pg_schema}

    introspect_opts = [
      schema: pg_schema,
      include_associations: Map.get(opts, :include_associations, true),
      expand: opts[:expand] || false
    ]

    config = SchemaIntrospector.introspect_schema(source, introspect_opts)

    config =
      if opts[:expand_schemas_list] do
        expand_shared_db_associations(
          config,
          conn,
          pg_schema,
          opts[:expand_schemas_list],
          introspect_opts
        )
      else
        config
      end

    config
    |> Map.put(:expand_schemas_list, opts[:expand_schemas_list] || [])
    |> Map.put(:expand, opts[:expand] || false)
    |> maybe_put_expand_modes(opts)
  end

  defp maybe_put_expand_modes(config, opts) do
    if opts[:expand_modes] && map_size(opts[:expand_modes]) > 0 do
      Map.put(config, :expand_modes, opts[:expand_modes])
    else
      config
    end
  end

  defp expand_shared_db_associations(domain_config, conn, pg_schema, expand_list, introspect_opts) do
    associations = domain_config[:associations] || %{}

    expanded_schemas =
      Enum.reduce(associations, %{}, fn {assoc_name, assoc_data}, acc ->
        related_table = assoc_data[:related_table]
        schema_key = related_schema_key(assoc_name, assoc_data)

        if should_expand_related_table?(schema_key, related_table, expand_list) and related_table do
          related_source =
            {:db, SelectoDBPostgreSQL.Adapter, conn, related_table,
             schema: pg_schema, include_associations: false, expand: false}

          related_opts =
            introspect_opts
            |> Keyword.put(:include_associations, false)
            |> Keyword.put(:expand, false)

          related_config = SchemaIntrospector.introspect_schema(related_source, related_opts)

          if Map.has_key?(related_config, :error) do
            acc
          else
            Map.put(acc, schema_key, %{
              source_table: related_config.table_name,
              table_name: related_config.table_name,
              primary_key: related_config.primary_key,
              fields: related_config.fields,
              field_types: related_config.field_types,
              associations: %{}
            })
          end
        else
          acc
        end
      end)

    Map.put(domain_config, :expanded_schemas, expanded_schemas)
  end

  defp related_schema_key(assoc_name, assoc_data) do
    cond do
      module_name = assoc_data[:related_module_name] ->
        module_name
        |> to_string()
        |> Macro.underscore()
        |> String.to_atom()

      related_schema = assoc_data[:related_schema] ->
        related_schema
        |> to_string()
        |> String.split(".")
        |> List.last()
        |> Macro.underscore()
        |> String.to_atom()

      related_table = assoc_data[:related_table] ->
        related_table
        |> singularize_table_name()
        |> String.to_atom()

      true ->
        assoc_name
    end
  end

  defp should_expand_related_table?(schema_key, related_table, expand_list) do
    schema_name = schema_key |> to_string() |> String.downcase()
    table_name = related_table |> to_string() |> String.downcase()

    Enum.any?(expand_list || [], fn expand_name ->
      expand_name = String.downcase(expand_name)

      expand_name == schema_name ||
        expand_name == table_name ||
        String.contains?(expand_name, schema_name) ||
        String.contains?(table_name, expand_name)
    end)
  end

  defp singularize_table_name(table_name) do
    cond do
      String.ends_with?(table_name, "ies") ->
        String.replace_suffix(table_name, "ies", "y")

      String.ends_with?(table_name, "sses") ->
        String.replace_suffix(table_name, "sses", "ss")

      String.ends_with?(table_name, "ses") ->
        String.replace_suffix(table_name, "ses", "s")

      String.ends_with?(table_name, "s") and not String.ends_with?(table_name, "ss") ->
        String.replace_suffix(table_name, "s", "")

      true ->
        table_name
    end
  end

  defp equivalent_selecto_mix_command(parsed_args) do
    (["mix selecto.gen.domain", "--adapter postgresql"] ++ equivalent_args(parsed_args))
    |> Enum.join(" ")
  end

  defp equivalent_args(parsed_args) do
    []
    |> maybe_add_bool_flag(parsed_args, :all, "--all")
    |> maybe_add_value_flag(parsed_args, :table, "--table")
    |> maybe_add_value_flag(parsed_args, :database_url, "--database-url")
    |> maybe_add_value_flag(parsed_args, :host, "--host")
    |> maybe_add_value_flag(parsed_args, :port, "--port")
    |> maybe_add_value_flag(parsed_args, :database, "--database")
    |> maybe_add_value_flag(parsed_args, :username, "--username")
    |> maybe_add_value_flag(parsed_args, :password, "--password")
    |> maybe_add_value_flag(parsed_args, :schema, "--schema")
    |> maybe_add_bool_flag(parsed_args, :include_associations, "--include-associations")
    |> maybe_add_bool_flag(parsed_args, :expand, "--expand")
    |> maybe_add_value_flag(parsed_args, :expand_schemas, "--expand-schemas")
    |> maybe_add_keep_flag(parsed_args, :expand_tag, "--expand-tag")
    |> maybe_add_keep_flag(parsed_args, :expand_star, "--expand-star")
    |> maybe_add_keep_flag(parsed_args, :expand_lookup, "--expand-lookup")
    |> maybe_add_keep_flag(parsed_args, :expand_polymorphic, "--expand-polymorphic")
    |> maybe_add_bool_flag(parsed_args, :parameterized_joins, "--parameterized-joins")
    |> maybe_add_bool_flag(parsed_args, :live, "--live")
    |> maybe_add_bool_flag(parsed_args, :saved_views, "--saved-views")
    |> maybe_add_value_flag(parsed_args, :path, "--path")
    |> maybe_add_value_flag(parsed_args, :output, "--output")
    |> maybe_add_bool_flag(parsed_args, :force, "--force")
    |> maybe_add_bool_flag(parsed_args, :dry_run, "--dry-run")
    |> maybe_add_bool_flag(parsed_args, :enable_modal, "--enable-modal")
    |> maybe_add_value_flag(parsed_args, :connection_name, "--connection-name")
    |> maybe_add_value_flag(parsed_args, :exclude, "--exclude")
  end

  defp delegate_to_selecto_mix(parsed_args) do
    case System.cmd(
           "mix",
           ["selecto.gen.domain", "--adapter", "postgresql"] ++ equivalent_args(parsed_args),
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        IO.puts(output)
        :ok

      {output, _exit_code} ->
        {:error, output}
    end
  end

  defp maybe_add_bool_flag(args, parsed_args, key, flag) do
    if parsed_args[key], do: args ++ [flag], else: args
  end

  defp maybe_add_value_flag(args, parsed_args, key, flag) do
    case parsed_args[key] do
      nil -> args
      value -> args ++ [flag, to_string(value)]
    end
  end

  defp maybe_add_keep_flag(args, parsed_args, key, flag) do
    case parsed_args[key] do
      values when is_list(values) -> Enum.reduce(values, args, &(&2 ++ [flag, &1]))
      nil -> args
      value -> args ++ [flag, to_string(value)]
    end
  end
end
