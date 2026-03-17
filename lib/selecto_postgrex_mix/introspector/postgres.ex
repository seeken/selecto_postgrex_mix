defmodule SelectoPostgrexMix.Introspector.Postgres do
  @moduledoc """
  Legacy compatibility wrapper around adapter-backed PostgreSQL introspection.

  Prefer `SelectoDBPostgreSQL.Adapter` or shared `SelectoMix` introspection APIs
  for new code.
  """

  @doc """
  List all tables in a schema through the PostgreSQL adapter.
  """
  def list_tables(conn, schema \\ "public") do
    postgresql_adapter().list_tables(conn, schema: schema)
  end

  @doc """
  Introspect a table through the PostgreSQL adapter.
  """
  def introspect_table(conn, table_name, opts \\ []) do
    postgresql_adapter().introspect_table(conn, table_name, opts)
  end

  @doc """
  Convert a table name to a likely module name segment.
  """
  def table_name_to_module(table_name) do
    table_name
    |> singularize()
    |> Macro.camelize()
  end

  @doc """
  Naive singularization for table names.
  """
  def singularize(word) do
    cond do
      String.ends_with?(word, "ies") ->
        String.replace_suffix(word, "ies", "y")

      String.ends_with?(word, "sses") ->
        String.replace_suffix(word, "sses", "ss")

      String.ends_with?(word, "ses") ->
        String.replace_suffix(word, "ses", "s")

      String.ends_with?(word, "s") and not String.ends_with?(word, "ss") ->
        String.replace_suffix(word, "s", "")

      true ->
        word
    end
  end

  defp postgresql_adapter do
    Module.concat(["SelectoDBPostgreSQL", "Adapter"])
  end
end
