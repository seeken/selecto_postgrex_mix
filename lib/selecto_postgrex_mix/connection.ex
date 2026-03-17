defmodule SelectoPostgrexMix.Connection do
  @moduledoc """
  Database connection management for SelectoPostgrexMix.

  Provides helpers for connecting to PostgreSQL databases during Mix task
  execution. Supports both `DATABASE_URL` environment variable and
  explicit connection parameters.

  ## Usage

      # Using DATABASE_URL
      {:ok, conn} = SelectoPostgrexMix.Connection.connect()

      # Using explicit options
      {:ok, conn} = SelectoPostgrexMix.Connection.connect(
        hostname: "localhost",
        port: 5432,
        database: "mydb",
        username: "postgres",
        password: "postgres"
      )

      # With auto-cleanup
      SelectoPostgrexMix.Connection.with_connection(fn conn ->
        {:ok, tables} = SelectoPostgrexMix.list_tables(conn)
        tables
      end)
  """

  require Logger

  alias SelectoMix.Connection, as: SharedConnection

  @doc """
  Parse a PostgreSQL database URL into connection options.

  ## Examples

      iex> parse_database_url("postgres://user:pass@localhost:5432/mydb")
      [hostname: "localhost", port: 5432, database: "mydb", username: "user", password: "pass"]

      iex> parse_database_url("postgresql://user:pass@host/db?sslmode=require")
      [hostname: "host", port: 5432, database: "db", username: "user", password: "pass"]
  """
  def parse_database_url(url) when is_binary(url) do
    SharedConnection.parse_database_url(url)
    |> Keyword.put_new(:port, 5432)
  end

  @doc """
  Connect to a PostgreSQL database.

  If no options are given, reads from `DATABASE_URL` environment variable.

  ## Options

    * `:hostname` - Database hostname (default: "localhost")
    * `:port` - Database port (default: 5432)
    * `:database` - Database name (required)
    * `:username` - Database username
    * `:password` - Database password
    * `:database_url` - Full database URL (overrides individual options)

  ## Returns

    * `{:ok, pid}` - Connection PID
    * `{:error, reason}` - Connection error
  """
  def connect(opts \\ []) do
    conn_opts = resolve_connection_opts(opts)
    SharedConnection.connect(postgresql_adapter(), conn_opts)
  end

  @doc """
  Disconnect from the database.
  """
  def disconnect(conn) when is_pid(conn) do
    SharedConnection.disconnect(conn)
  end

  def disconnect(_), do: :ok

  @doc """
  Connect, run a function, then disconnect.

  ## Examples

      result = SelectoPostgrexMix.Connection.with_connection(fn conn ->
        {:ok, tables} = SelectoPostgrexMix.list_tables(conn)
        tables
      end)

      result = SelectoPostgrexMix.Connection.with_connection(
        [database: "mydb"],
        fn conn ->
          SelectoPostgrexMix.Introspector.Postgres.introspect_table(conn, "users")
        end
      )
  """
  def with_connection(opts \\ [], fun) when is_function(fun, 1) do
    case SharedConnection.with_connection(
           postgresql_adapter(),
           resolve_connection_opts(opts),
           fun
         ) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolve connection options from multiple sources.

  Priority (highest to lowest):
  1. Explicit `:database_url` option
  2. Explicit connection parameters (`:hostname`, `:database`, etc.)
  3. `DATABASE_URL` environment variable
  4. Current Mix project's first Ecto repo configuration
  """
  def resolve_connection_opts(opts \\ []) do
    cond do
      # Explicit database_url option
      url = Keyword.get(opts, :database_url) ->
        parse_database_url(url)

      # Explicit connection params provided
      Keyword.has_key?(opts, :database) ->
        opts
        |> Keyword.take([:hostname, :port, :database, :username, :password])
        |> Keyword.put_new(:hostname, "localhost")
        |> Keyword.put_new(:port, 5432)

      # Fall back to DATABASE_URL env var
      url = System.get_env("DATABASE_URL") ->
        parse_database_url(url)

      # Fall back to current project's Ecto repo config
      repo_opts = repo_connection_opts_from_current_project() ->
        repo_opts

      true ->
        raise """
        No database connection configured.

        Provide one of:
          1. DATABASE_URL environment variable
          2. --database-url flag
          3. --database, --hostname, --username, --password flags
          4. Configure ecto_repos + Repo config in your current Mix project
        """
    end
  end

  defp postgresql_adapter do
    Module.concat(["SelectoDBPostgreSQL", "Adapter"])
  end

  defp repo_connection_opts_from_current_project do
    case Mix.Project.get() do
      nil ->
        nil

      project ->
        app = project.project()[:app]

        with true <- not is_nil(app),
             repos when is_list(repos) <- Application.get_env(app, :ecto_repos, []),
             [repo | _] <- repos,
             repo_config when is_list(repo_config) <- Application.get_env(app, repo, []),
             opts when is_list(opts) <- normalize_repo_config_to_connection_opts(repo_config),
             true <- opts != [] do
          opts
        else
          _ -> nil
        end
    end
  end

  defp normalize_repo_config_to_connection_opts(repo_config) do
    cond do
      url = Keyword.get(repo_config, :url) ->
        parse_database_url(url)

      url = Keyword.get(repo_config, :database_url) ->
        parse_database_url(url)

      true ->
        repo_config
        |> Keyword.take([:hostname, :port, :database, :username, :password])
        |> Keyword.put_new(:hostname, "localhost")
        |> Keyword.put_new(:port, 5432)
        |> then(fn opts ->
          if Keyword.get(opts, :database), do: opts, else: []
        end)
    end
  end
end
