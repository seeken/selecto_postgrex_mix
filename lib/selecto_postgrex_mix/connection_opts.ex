defmodule SelectoPostgrexMix.ConnectionOpts do
  @moduledoc """
  Shared helper for parsing database connection flags across all mix tasks.
  """

  @doc """
  Parse connection-related options from a parsed args map.

  Returns keyword list suitable for `SelectoPostgrexMix.Connection.connect/1`.
  """
  def from_parsed_args(parsed_args) do
    cond do
      url = parsed_args[:database_url] ->
        [database_url: url]

      parsed_args[:database] ->
        opts = [database: parsed_args[:database]]
        opts = if parsed_args[:host], do: Keyword.put(opts, :hostname, parsed_args[:host]), else: opts
        opts = if parsed_args[:port], do: Keyword.put(opts, :port, parsed_args[:port]), else: opts
        opts = if parsed_args[:username], do: Keyword.put(opts, :username, parsed_args[:username]), else: opts
        opts = if parsed_args[:password], do: Keyword.put(opts, :password, parsed_args[:password]), else: opts
        opts

      url = System.get_env("DATABASE_URL") ->
        [database_url: url]

      true ->
        []
    end
  end

  @doc """
  Returns the Igniter option schema for database connection flags.
  """
  def connection_schema do
    [
      database_url: :string,
      host: :string,
      port: :integer,
      database: :string,
      username: :string,
      password: :string,
      connection_name: :string,
      schema: :string
    ]
  end

  @doc """
  Returns Igniter aliases for database connection flags.
  """
  def connection_aliases do
    [
      u: :database_url,
      h: :host,
      P: :port,
      D: :database,
      U: :username,
      W: :password
    ]
  end

  @doc """
  System tables and migration tables to exclude when listing all tables.
  """
  def system_tables do
    [
      "schema_migrations",
      "ar_internal_metadata",
      "pg_stat_statements",
      "spatial_ref_sys"
    ]
  end
end
