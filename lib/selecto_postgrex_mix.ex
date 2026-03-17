defmodule SelectoPostgrexMix do
  @moduledoc """
  Compatibility wrappers for PostgreSQL-oriented Selecto generation.

  SelectoPostgrexMix provides PostgreSQL-oriented compatibility tasks during the
  consolidation into `selecto_mix`.

  Domain generation now routes through the shared `selecto_mix` flow, while
  PostgreSQL-specific compatibility wrappers remain available for:

  - Projects that don't use Ecto
  - Generating domains from existing databases
  - Working with projects that still call the old `selecto_postgrex.*` commands
  - Transitional compatibility while moving docs/scripts to `selecto_mix`

  ## Main Mix Tasks

  - `mix selecto_postgrex.gen.domain` - Compatibility wrapper to `mix selecto.gen.domain --adapter postgresql`
  - `mix selecto_postgrex.gen.saved_views` - Compatibility wrapper to `mix selecto.gen.saved_views --adapter postgresql`
  - `mix selecto_postgrex.gen.filter_sets` - Compatibility wrapper to `mix selecto.gen.filter_sets --adapter postgresql`
  - `mix selecto_postgrex.gen.saved_view_configs` - Compatibility wrapper to `mix selecto.gen.saved_view_configs --adapter postgresql`
  - `mix selecto_postgrex.install` - Compatibility wrapper to `mix selecto.install`
  - `mix selecto_postgrex.components.integrate` - Compatibility wrapper to shared assets integration
  - `mix selecto_postgrex.gen.live_dashboard` - Compatibility wrapper to shared dashboard generation
  - `mix selecto_postgrex.gen.parameterized_join` - Compatibility wrapper to shared parameterized join generation
  - `mix selecto_postgrex.validate.parameterized_joins` - Compatibility wrapper to shared parameterized join validation
  - `mix selecto_postgrex.setup` - Compatibility wrapper to `mix selecto.setup --adapter postgresql`
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
    Code.ensure_loaded?(SelectoDBPostgreSQL.Adapter) and Code.ensure_loaded?(Selecto)
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
end
