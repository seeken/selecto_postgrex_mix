defmodule SelectoPostgrexMix.Introspector.Postgres do
  @moduledoc """
  Introspects PostgreSQL databases directly using system catalogs.

  Works with Postgrex connections without requiring Ecto schemas. Uses
  information_schema and pg_catalog to discover table structure, relationships,
  and constraints.

  ## Usage

      {:ok, conn} = Postgrex.start_link(hostname: "localhost", database: "mydb")

      # List all tables
      {:ok, tables} = SelectoPostgrexMix.Introspector.Postgres.list_tables(conn)

      # Introspect specific table
      {:ok, metadata} = SelectoPostgrexMix.Introspector.Postgres.introspect_table(conn, "users")
  """

  require Logger

  @doc """
  List all tables in a schema.

  ## Parameters

  - `conn` - Postgrex connection (PID or named process)
  - `schema` - Schema name (default: "public")

  ## Returns

  - `{:ok, [table_name, ...]}` - List of table names
  - `{:error, reason}` - Error details
  """
  def list_tables(conn, schema \\ "public") do
    query = """
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = $1
      AND table_type = 'BASE TABLE'
    ORDER BY table_name
    """

    case Postgrex.query(conn, query, [schema]) do
      {:ok, %{rows: rows}} ->
        tables = Enum.map(rows, fn [table_name] -> table_name end)
        {:ok, tables}

      {:error, error} ->
        {:error, {:query_failed, error}}
    end
  end

  @doc """
  Introspect a table and return complete metadata.

  Returns standardized metadata structure compatible with Selecto domain generation.

  ## Parameters

  - `conn` - Postgrex connection
  - `table_name` - Table name
  - `opts` - Options
    - `:schema` - Schema name (default: "public")
    - `:include_indexes` - Include index information (default: false)

  ## Returns

  - `{:ok, metadata}` - Table metadata map
  - `{:error, reason}` - Error details
  """
  def introspect_table(conn, table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")

    with {:ok, columns} <- get_columns(conn, table_name, schema),
         {:ok, primary_key} <- get_primary_key(conn, table_name, schema),
         {:ok, foreign_keys} <- get_foreign_keys(conn, table_name, schema) do
      # Extract field names and types
      fields = Enum.map(columns, & &1.column_name)

      field_types =
        columns
        |> Enum.into(%{}, fn col ->
          elixir_type = map_pg_type(col.data_type, col.udt_name, conn)
          {col.column_name, elixir_type}
        end)

      # Build associations from foreign keys
      associations = build_associations(foreign_keys)

      # Build detailed column metadata
      column_metadata =
        columns
        |> Enum.into(%{}, fn col ->
          {col.column_name,
           %{
             type: Map.get(field_types, col.column_name),
             nullable: col.is_nullable == "YES",
             default: col.column_default,
             max_length: col.character_maximum_length,
             precision: col.numeric_precision,
             scale: col.numeric_scale
           }}
        end)

      metadata = %{
        table_name: table_name,
        schema: schema,
        fields: fields,
        field_types: field_types,
        primary_key: primary_key,
        associations: associations,
        columns: column_metadata,
        source: :postgres
      }

      {:ok, metadata}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get column definitions for a table.
  """
  def get_columns(conn, table_name, schema \\ "public") do
    query = """
    SELECT
      column_name,
      data_type,
      udt_name,
      is_nullable,
      column_default,
      character_maximum_length,
      numeric_precision,
      numeric_scale,
      ordinal_position
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2
    ORDER BY ordinal_position
    """

    case Postgrex.query(conn, query, [schema, table_name]) do
      {:ok, %{rows: rows}} ->
        columns =
          rows
          |> Enum.map(fn [col_name, data_type, udt_name, is_nullable, col_default,
                          max_length, precision, scale, _position] ->
            %{
              column_name: String.to_atom(col_name),
              data_type: data_type,
              udt_name: udt_name,
              is_nullable: is_nullable,
              column_default: col_default,
              character_maximum_length: max_length,
              numeric_precision: precision,
              numeric_scale: scale
            }
          end)

        {:ok, columns}

      {:error, error} ->
        {:error, {:columns_query_failed, error}}
    end
  end

  @doc """
  Get primary key column(s) for a table.
  """
  def get_primary_key(conn, table_name, schema \\ "public") do
    query = """
    SELECT a.attname
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid
      AND a.attnum = ANY(i.indkey)
    WHERE i.indrelid = ($1 || '.' || $2)::regclass
      AND i.indisprimary
    ORDER BY a.attnum
    """

    case Postgrex.query(conn, query, [schema, table_name]) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{rows: [[single_key]]}} ->
        {:ok, String.to_atom(single_key)}

      {:ok, %{rows: multiple_keys}} ->
        keys = Enum.map(multiple_keys, fn [key] -> String.to_atom(key) end)
        {:ok, keys}

      {:error, error} ->
        {:error, {:primary_key_query_failed, error}}
    end
  end

  @doc """
  Get foreign key relationships for a table.
  """
  def get_foreign_keys(conn, table_name, schema \\ "public") do
    query = """
    SELECT
      tc.constraint_name,
      kcu.column_name,
      ccu.table_schema AS foreign_table_schema,
      ccu.table_name AS foreign_table_name,
      ccu.column_name AS foreign_column_name
    FROM information_schema.table_constraints AS tc
    JOIN information_schema.key_column_usage AS kcu
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage AS ccu
      ON ccu.constraint_name = tc.constraint_name
      AND ccu.table_schema = tc.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND tc.table_schema = $1
      AND tc.table_name = $2
    """

    case Postgrex.query(conn, query, [schema, table_name]) do
      {:ok, %{rows: rows}} ->
        foreign_keys =
          rows
          |> Enum.map(fn [constraint_name, col_name, foreign_schema,
                          foreign_table, foreign_col] ->
            %{
              constraint_name: constraint_name,
              column_name: String.to_atom(col_name),
              foreign_table_schema: foreign_schema,
              foreign_table_name: foreign_table,
              foreign_column_name: String.to_atom(foreign_col)
            }
          end)

        {:ok, foreign_keys}

      {:error, error} ->
        {:error, {:foreign_keys_query_failed, error}}
    end
  end

  @doc """
  Get index definitions for a table.
  """
  def get_indexes(conn, table_name, schema \\ "public") do
    query = """
    SELECT
      i.relname AS index_name,
      a.attname AS column_name,
      ix.indisunique AS is_unique,
      ix.indisprimary AS is_primary
    FROM pg_class t
    JOIN pg_index ix ON t.oid = ix.indrelid
    JOIN pg_class i ON i.oid = ix.indexrelid
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = $1
      AND t.relname = $2
    ORDER BY i.relname, a.attnum
    """

    case Postgrex.query(conn, query, [schema, table_name]) do
      {:ok, %{rows: rows}} ->
        indexes =
          rows
          |> Enum.map(fn [index_name, col_name, is_unique, is_primary] ->
            %{
              index_name: index_name,
              column_name: String.to_atom(col_name),
              is_unique: is_unique,
              is_primary: is_primary
            }
          end)

        {:ok, indexes}

      {:error, error} ->
        {:error, {:indexes_query_failed, error}}
    end
  end

  @doc """
  Get enum values for a PostgreSQL enum type.
  """
  def get_enum_values(conn, enum_type_name) do
    query = """
    SELECT e.enumlabel
    FROM pg_type t
    JOIN pg_enum e ON t.oid = e.enumtypid
    WHERE t.typname = $1
    ORDER BY e.enumsortorder
    """

    case Postgrex.query(conn, query, [enum_type_name]) do
      {:ok, %{rows: []}} ->
        {:error, :enum_not_found}

      {:ok, %{rows: rows}} ->
        values = Enum.map(rows, fn [value] -> value end)
        {:ok, values}

      {:error, error} ->
        {:error, {:enum_query_failed, error}}
    end
  end

  @doc """
  Map PostgreSQL type to Elixir/Selecto type.
  """
  def map_pg_type(data_type, udt_name \\ nil, conn \\ nil)

  # Integer types
  def map_pg_type("integer", _, _), do: :integer
  def map_pg_type("bigint", _, _), do: :integer
  def map_pg_type("smallint", _, _), do: :integer
  def map_pg_type("int2", _, _), do: :integer
  def map_pg_type("int4", _, _), do: :integer
  def map_pg_type("int8", _, _), do: :integer

  # String types
  def map_pg_type("character varying", _, _), do: :string
  def map_pg_type("varchar", _, _), do: :string
  def map_pg_type("character", _, _), do: :string
  def map_pg_type("char", _, _), do: :string
  def map_pg_type("text", _, _), do: :string

  # Boolean
  def map_pg_type("boolean", _, _), do: :boolean
  def map_pg_type("bool", _, _), do: :boolean

  # Numeric/Decimal
  def map_pg_type("numeric", _, _), do: :decimal
  def map_pg_type("decimal", _, _), do: :decimal
  def map_pg_type("money", _, _), do: :decimal

  # Float/Double
  def map_pg_type("real", _, _), do: :float
  def map_pg_type("double precision", _, _), do: :float
  def map_pg_type("float4", _, _), do: :float
  def map_pg_type("float8", _, _), do: :float

  # Date/Time types
  def map_pg_type("timestamp without time zone", _, _), do: :naive_datetime
  def map_pg_type("timestamp with time zone", _, _), do: :utc_datetime
  def map_pg_type("timestamp", _, _), do: :naive_datetime
  def map_pg_type("timestamptz", _, _), do: :utc_datetime
  def map_pg_type("date", _, _), do: :date
  def map_pg_type("time", _, _), do: :time
  def map_pg_type("time without time zone", _, _), do: :time
  def map_pg_type("time with time zone", _, _), do: :time

  # UUID
  def map_pg_type("uuid", _, _), do: :binary_id

  # JSON
  def map_pg_type("json", _, _), do: :map
  def map_pg_type("jsonb", _, _), do: :map

  # Binary
  def map_pg_type("bytea", _, _), do: :binary

  # Array types
  def map_pg_type("ARRAY", udt_name, conn) do
    inner_type =
      udt_name
      |> String.trim_leading("_")
      |> then(&map_pg_type(&1, nil, conn))

    {:array, inner_type}
  end

  # User-defined types (likely enums)
  def map_pg_type("USER-DEFINED", udt_name, conn) when not is_nil(udt_name) do
    if conn do
      case get_enum_values(conn, udt_name) do
        {:ok, _values} -> :string
        {:error, _} -> :string
      end
    else
      :string
    end
  end

  # Default fallback
  def map_pg_type(_data_type, _udt_name, _conn), do: :string

  # Private helper functions

  defp build_associations(foreign_keys) do
    foreign_keys
    |> Enum.into(%{}, fn fk ->
      assoc_name =
        fk.column_name
        |> Atom.to_string()
        |> String.replace_suffix("_id", "")
        |> String.to_atom()

      related_module_name = table_name_to_module(fk.foreign_table_name)

      association = %{
        type: :belongs_to,
        queryable: String.to_atom(fk.foreign_table_name),
        field: assoc_name,
        owner_key: fk.column_name,
        related_key: fk.foreign_column_name,
        related_table: fk.foreign_table_name,
        related_module_name: related_module_name,
        constraint_name: fk.constraint_name
      }

      {assoc_name, association}
    end)
  end

  @doc """
  Convert a table name to a likely module name segment.

  ## Examples

      iex> table_name_to_module("categories")
      "Category"

      iex> table_name_to_module("order_details")
      "OrderDetail"
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

      String.ends_with?(word, "s") && !String.ends_with?(word, "ss") ->
        String.replace_suffix(word, "s", "")

      true ->
        word
    end
  end
end
