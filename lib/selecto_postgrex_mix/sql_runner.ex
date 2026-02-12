defmodule SelectoPostgrexMix.SqlRunner do
  @moduledoc """
  Utility to execute SQL files via Postgrex.
  """

  alias SelectoPostgrexMix.Connection

  @doc """
  Execute all SQL files in a directory.

  ## Options

    * `:conn_opts` - Connection options for Postgrex
    * `:pattern` - Glob pattern for SQL files (default: "*.sql")
  """
  def run_sql_directory(dir, opts \\ []) do
    conn_opts = Keyword.get(opts, :conn_opts, [])
    pattern = Keyword.get(opts, :pattern, "*.sql")

    sql_files =
      Path.join(dir, pattern)
      |> Path.wildcard()
      |> Enum.sort()

    if Enum.empty?(sql_files) do
      {:ok, :no_files}
    else
      Connection.with_connection(conn_opts, fn conn ->
        results =
          Enum.map(sql_files, fn file ->
            run_sql_file(conn, file)
          end)

        errors = Enum.filter(results, &match?({:error, _, _}, &1))

        if Enum.empty?(errors) do
          {:ok, length(sql_files)}
        else
          {:error, errors}
        end
      end)
    end
  end

  @doc """
  Execute a single SQL file.
  """
  def run_sql_file(conn, file_path) do
    case File.read(file_path) do
      {:ok, sql} ->
        run_sql_string(conn, sql, file_path)

      {:error, reason} ->
        {:error, file_path, {:file_read_error, reason}}
    end
  end

  @doc """
  Execute a SQL string, splitting on semicolons for multi-statement support.
  """
  def run_sql_string(conn, sql, label \\ "inline") do
    statements =
      sql
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    results =
      Enum.map(statements, fn stmt ->
        case Postgrex.query(conn, stmt, []) do
          {:ok, result} -> {:ok, result}
          {:error, error} -> {:error, label, error}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _, _}, &1))

    if Enum.empty?(errors) do
      {:ok, label, length(statements)}
    else
      List.first(errors)
    end
  end
end
