defmodule SelectoPostgrexMix do
  @moduledoc """
  Mix tasks for Selecto domain generation via direct Postgrex introspection.

  SelectoPostgrexMix provides PostgreSQL-oriented compatibility tasks during the
  consolidation into `selecto_mix`.

  Domain generation now routes through the shared `selecto_mix` flow where possible,
  while PostgreSQL-specific compatibility wrappers remain available for:

  - Projects that don't use Ecto
  - Generating domains from existing databases
  - Working with databases where Ecto schemas haven't been defined yet
  - Polyglot environments where the database is shared across languages

  ## Main Mix Tasks

  - `mix selecto_postgrex.gen.domain` - Generate Selecto domain from database tables
  - `mix selecto_postgrex.gen.saved_views` - Generate saved views infrastructure
  - `mix selecto_postgrex.gen.filter_sets` - Generate filter sets infrastructure
  - `mix selecto_postgrex.gen.saved_view_configs` - Generate view configs infrastructure
  - `mix selecto_postgrex.install` - Install Selecto Postgrex dependencies
  - `mix selecto_postgrex.components.integrate` - Compatibility wrapper to shared assets integration
  - `mix selecto_postgrex.gen.live_dashboard` - Compatibility wrapper to shared dashboard generation
  - `mix selecto_postgrex.gen.parameterized_join` - Compatibility wrapper to shared parameterized join generation
  - `mix selecto_postgrex.validate.parameterized_joins` - Compatibility wrapper to shared parameterized join validation
  - `mix selecto_postgrex.setup` - Run generated SQL files
  - `mix selecto_postgrex.add_timeouts` - Configure query timeouts

  ## Getting Started

      # Generate domain for a single table
      DATABASE_URL="postgres://user:pass@localhost/mydb" \\
        mix selecto_postgrex.gen.domain --table products --expand --live

      # Generate for all tables
      DATABASE_URL="postgres://user:pass@localhost/mydb" \\
        mix selecto_postgrex.gen.domain --all --live
  """

  @doc """
  Get the version of SelectoPostgrexMix.
  """
  def version do
    Application.spec(:selecto_postgrex_mix, :vsn) |> to_string()
  end

  @doc """
  Get configuration for SelectoPostgrexMix.
  """
  def config do
    Application.get_all_env(:selecto_postgrex_mix)
  end

  @doc """
  Check if required runtime dependencies are available.
  """
  def dependencies_available? do
    Code.ensure_loaded?(Postgrex) and Code.ensure_loaded?(Selecto)
  end

  @doc """
  Get the default output directory for generated domains.
  """
  def default_output_dir do
    case Application.get_env(:selecto_postgrex_mix, :output_dir) do
      nil ->
        app_name = Application.get_env(:selecto_postgrex_mix, :app_name, "my_app")
        "lib/#{app_name}/selecto_domains"

      dir ->
        dir
    end
  end

  @doc """
  List tables in a database using a Postgrex connection.
  """
  def list_tables(conn, schema \\ "public") do
    SelectoPostgrexMix.Introspector.Postgres.list_tables(conn, schema)
  end
end
