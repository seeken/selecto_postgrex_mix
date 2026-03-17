defmodule SelectoPostgrexMix.ConnectionOpts do
  @moduledoc """
  Shared helper for parsing database connection flags across all mix tasks.
  """

  alias SelectoMix.ConnectionOpts, as: SharedConnectionOpts

  @doc """
  Parse connection-related options from a parsed args map.

  Returns keyword list suitable for `SelectoPostgrexMix.Connection.connect/1`.
  """
  def from_parsed_args(parsed_args) do
    SharedConnectionOpts.from_parsed_args(parsed_args)
  end

  @doc """
  Returns the Igniter option schema for database connection flags.
  """
  def connection_schema do
    SharedConnectionOpts.connection_schema()
    |> Keyword.drop([:adapter, :table, :expand])
  end

  @doc """
  Returns Igniter aliases for database connection flags.
  """
  def connection_aliases do
    SharedConnectionOpts.connection_aliases()
    |> Keyword.drop([:A, :t])
  end

  @doc """
  System tables and migration tables to exclude when listing all tables.
  """
  def system_tables do
    SharedConnectionOpts.system_tables()
  end
end
