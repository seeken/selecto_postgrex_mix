defmodule SelectoPostgrexMix.Introspector.Expand do
  @moduledoc """
  Expansion utilities for discovering reverse foreign keys and junction tables.

  Enables the `--expand` flag by finding tables that reference a given table
  (reverse FKs) and detecting many-to-many junction tables.
  """

  alias SelectoPostgrexMix.Introspector.Postgres

  @doc """
  Get tables that have foreign keys pointing TO a given table.

  This enables `--expand` by discovering has_many relationships
  (i.e., other tables that reference this table via FK).

  ## Parameters

  - `conn` - Postgrex connection
  - `table_name` - The target table name
  - `schema` - PostgreSQL schema (default: "public")

  ## Returns

  - `{:ok, [reverse_fk_info, ...]}` - List of reverse FK maps
  - `{:error, reason}` - Error
  """
  def get_reverse_foreign_keys(conn, table_name, schema \\ "public") do
    query = """
    SELECT
      tc.table_name AS referencing_table,
      kcu.column_name AS referencing_column,
      tc.constraint_name
    FROM information_schema.table_constraints AS tc
    JOIN information_schema.key_column_usage AS kcu
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage AS ccu
      ON ccu.constraint_name = tc.constraint_name
      AND ccu.table_schema = tc.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND ccu.table_schema = $1
      AND ccu.table_name = $2
    ORDER BY tc.table_name
    """

    case Postgrex.query(conn, query, [schema, table_name]) do
      {:ok, %{rows: rows}} ->
        reverse_fks =
          rows
          |> Enum.map(fn [ref_table, ref_column, constraint_name] ->
            %{
              referencing_table: ref_table,
              referencing_column: String.to_atom(ref_column),
              constraint_name: constraint_name
            }
          end)

        {:ok, reverse_fks}

      {:error, error} ->
        {:error, {:reverse_fk_query_failed, error}}
    end
  end

  @doc """
  Detect junction tables suitable for many-to-many relationships.

  A junction table heuristic: table has exactly 2 FK columns that together
  form the primary key (or are the only non-PK columns).

  ## Returns

  - `{:ok, [junction_info, ...]}` - List of detected junction tables
  """
  def detect_junction_tables(conn, schema \\ "public") do
    {:ok, tables} = Postgres.list_tables(conn, schema)

    junctions =
      tables
      |> Enum.filter(fn table ->
        case analyze_as_junction(conn, table, schema) do
          {:ok, true} -> true
          _ -> false
        end
      end)
      |> Enum.map(fn table ->
        {:ok, fks} = Postgres.get_foreign_keys(conn, table, schema)
        {:ok, pk} = Postgres.get_primary_key(conn, table, schema)
        {:ok, columns} = Postgres.get_columns(conn, table, schema)

        fk_columns = Enum.map(fks, & &1.column_name)
        all_columns = Enum.map(columns, & &1.column_name)

        # Non-FK, non-PK columns (e.g. timestamps, extra data)
        pk_list = if is_list(pk), do: pk, else: [pk]
        extra_columns = all_columns -- (fk_columns ++ pk_list)

        %{
          table: table,
          foreign_keys: fks,
          primary_key: pk,
          extra_columns: extra_columns,
          tables: Enum.map(fks, & &1.foreign_table_name)
        }
      end)

    {:ok, junctions}
  end

  @doc """
  Build expanded associations for a table including reverse FKs.

  Returns both belongs_to (from FKs on this table) and has_many
  (from reverse FKs pointing to this table).
  """
  def build_expanded_associations(conn, table_name, schema \\ "public") do
    with {:ok, fks} <- Postgres.get_foreign_keys(conn, table_name, schema),
         {:ok, reverse_fks} <- get_reverse_foreign_keys(conn, table_name, schema),
         {:ok, junctions} <- detect_junction_tables(conn, schema) do
      # belongs_to from this table's FKs
      belongs_to =
        fks
        |> Enum.into(%{}, fn fk ->
          assoc_name =
            fk.column_name
            |> Atom.to_string()
            |> String.replace_suffix("_id", "")
            |> String.to_atom()

          {assoc_name,
           %{
             type: :belongs_to,
             queryable: String.to_atom(fk.foreign_table_name),
             field: assoc_name,
             owner_key: fk.column_name,
             related_key: fk.foreign_column_name,
             related_table: fk.foreign_table_name,
             related_module_name: Postgres.table_name_to_module(fk.foreign_table_name)
           }}
        end)

      # has_many from reverse FKs
      has_many =
        reverse_fks
        |> Enum.into(%{}, fn rfk ->
          assoc_name = String.to_atom(rfk.referencing_table)

          {assoc_name,
           %{
             type: :has_many,
             queryable: String.to_atom(rfk.referencing_table),
             field: assoc_name,
             owner_key: :id,
             related_key: rfk.referencing_column,
             related_table: rfk.referencing_table,
             related_module_name: Postgres.table_name_to_module(rfk.referencing_table)
           }}
        end)

      # many_to_many from junction tables involving this table
      many_to_many =
        junctions
        |> Enum.filter(fn j -> table_name in j.tables end)
        |> Enum.flat_map(fn j ->
          # Find the FK pointing to THIS table and the FK pointing to the OTHER table
          {this_fk, other_fks} =
            Enum.split_with(j.foreign_keys, fn fk ->
              fk.foreign_table_name == table_name
            end)

          Enum.map(other_fks, fn other_fk ->
            assoc_name = String.to_atom(other_fk.foreign_table_name)

            this_column =
              case this_fk do
                [fk | _] -> fk.column_name
                _ -> :id
              end

            {assoc_name,
             %{
               type: :many_to_many,
               queryable: String.to_atom(other_fk.foreign_table_name),
               field: assoc_name,
               owner_key: :id,
               related_key: other_fk.foreign_column_name,
               related_table: other_fk.foreign_table_name,
               related_module_name: Postgres.table_name_to_module(other_fk.foreign_table_name),
               join_through: j.table,
               join_keys: [
                 {this_column, :id},
                 {other_fk.column_name, other_fk.foreign_column_name}
               ]
             }}
          end)
        end)
        |> Enum.into(%{})

      all_associations =
        belongs_to
        |> Map.merge(has_many)
        |> Map.merge(many_to_many)

      {:ok, all_associations}
    end
  end

  # Private

  defp analyze_as_junction(conn, table, schema) do
    with {:ok, columns} <- Postgres.get_columns(conn, table, schema),
         {:ok, fks} <- Postgres.get_foreign_keys(conn, table, schema) do
      fk_columns = MapSet.new(Enum.map(fks, & &1.column_name))
      all_columns = Enum.map(columns, & &1.column_name)

      # Filter out common non-data columns
      data_columns =
        Enum.reject(all_columns, fn col ->
          col_str = Atom.to_string(col)

          col_str in ["id", "inserted_at", "updated_at", "created_at"] or
            String.ends_with?(col_str, "_at")
        end)

      # Junction table: all data columns are FK columns, and there are exactly 2
      is_junction =
        length(fks) == 2 and
          Enum.all?(data_columns, fn col -> MapSet.member?(fk_columns, col) end)

      {:ok, is_junction}
    end
  end
end
