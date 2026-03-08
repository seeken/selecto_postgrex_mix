defmodule SelectoPostgrexMix.OverlayGenerator do
  @moduledoc """
  Generates overlay configuration files for domain customization.

  Overlay files allow users to customize domain configurations without
  modifying the generated domain files, enabling safe regeneration.
  """

  @doc """
  Generates an overlay file template for a domain.
  """
  def generate_overlay_file(module_name, config, _opts \\ []) do
    overlay_module_name = overlay_module_name(module_name)
    column_examples = generate_column_examples_dsl(config)
    filter_examples = generate_filter_examples_dsl(config)
    redaction_example = generate_redaction_example(config)
    jsonb_examples = generate_jsonb_schema_examples(config)
    query_member_examples = generate_query_member_examples_dsl()

    """
    defmodule #{overlay_module_name} do
      @moduledoc \"\"\"
      Overlay configuration for #{module_name}.

      This file contains user-defined customizations for the domain configuration.
      It will NOT be overwritten when you regenerate the domain file.

      ## DSL Usage

          @redactions [:field1, :field2]

          defcolumn :price do
            label "Product Price"
            format :currency
            aggregate_functions [:sum, :avg]
          end

          deffilter "price_range" do
            name "Price Range"
            type :string
          end

          defcte :active_rows do
            query &__MODULE__.active_rows_cte/1
            columns ["id"]
            join [owner_key: :id, related_key: :id]
          end

          defvalues :status_lookup do
            rows [["active", "Active"], ["inactive", "Inactive"]]
            columns ["status", "label"]
            as "status_lookup"
          end

          defsubquery :high_value_rows do
            query &__MODULE__.high_value_rows_subquery/1
            on [%{left: "id", right: "entity_id"}]
          end

          deflateral :recent_series do
            source {:function, :generate_series, [1, 3]}
            as "recent_series"
            join_type :inner
          end

          defunnest :tag_values do
            array_field "tags"
            as "tag_value"
            ordinality "tag_position"
          end
      \"\"\"

      use Selecto.Config.OverlayDSL

      # Uncomment to redact sensitive fields from query results
      #{redaction_example}

      # Uncomment and customize column configurations as needed
    #{column_examples}

      # Uncomment and add custom filters
    #{filter_examples}
    #{query_member_examples}
    #{jsonb_examples}
    end
    """
  end

  @doc """
  Generates the overlay module name from the domain module name.
  """
  def overlay_module_name(domain_module_name) do
    parts = String.split(domain_module_name, ".")
    {last, prefix} = List.pop_at(parts, -1)

    overlay_name = last <> "Overlay"
    (prefix ++ ["Overlays", overlay_name]) |> Enum.join(".")
  end

  @doc """
  Generates the overlay file path from the domain file path.
  """
  def overlay_file_path(domain_file_path) do
    dir = Path.dirname(domain_file_path)
    basename = Path.basename(domain_file_path, ".ex")
    overlay_basename = basename <> "_overlay.ex"

    Path.join([dir, "overlays", overlay_basename])
  end

  # Private helper functions

  defp generate_redaction_example(config) do
    columns = extract_columns(config)

    sensitive_fields =
      columns
      |> Enum.filter(fn {field_name, _} ->
        field_str = to_string(field_name)

        String.contains?(field_str, "password") ||
          String.contains?(field_str, "secret") ||
          String.contains?(field_str, "token") ||
          String.contains?(field_str, "key") ||
          String.contains?(field_str, "internal")
      end)
      |> Enum.map(fn {field_name, _} -> field_name end)
      |> Enum.take(3)

    if length(sensitive_fields) > 0 do
      fields_list = Enum.map_join(sensitive_fields, ", ", &inspect/1)
      "# @redactions [#{fields_list}]"
    else
      "# @redactions [:sensitive_field1, :sensitive_field2]"
    end
  end

  defp generate_column_examples_dsl(config) do
    columns = extract_columns(config)

    examples =
      columns
      |> Enum.take(3)
      |> Enum.map(fn {field_name, column_config} ->
        generate_column_example_dsl(field_name, column_config)
      end)
      |> Enum.join("\n\n")

    if examples == "" do
      """
        # defcolumn :field_name do
        #   label "Custom Label"
        #   format :currency
        #   aggregate_functions [:sum, :avg, :min, :max]
        # end
      """
    else
      examples
    end
  end

  defp generate_column_example_dsl(field_name, column_config) do
    type = column_type(column_config, %{})

    case type do
      :decimal ->
        """
          # defcolumn :#{field_name} do
          #   label "#{humanize(field_name)}"
          #   format :currency
          #   precision 2
          #   aggregate_functions [:sum, :avg, :min, :max]
          # end
        """

      :integer ->
        """
          # defcolumn :#{field_name} do
          #   label "#{humanize(field_name)}"
          #   aggregate_functions [:sum, :avg, :count, :min, :max]
          # end
        """

      :boolean ->
        """
          # defcolumn :#{field_name} do
          #   label "#{humanize(field_name)}"
          #   format :yes_no
          # end
        """

      _ ->
        """
          # defcolumn :#{field_name} do
          #   label "#{humanize(field_name)}"
          #   max_length 100
          # end
        """
    end
    |> String.trim_trailing()
  end

  defp generate_filter_examples_dsl(config) do
    columns = extract_columns(config)

    example_field =
      columns
      |> Enum.find(fn {_field, col_config} ->
        column_type(col_config, columns) in [:string, :integer, :decimal, :boolean]
      end)

    case example_field do
      {field_name, col_config} ->
        case column_type(col_config, columns) do
          :string ->
            """
              # deffilter "#{field_name}_search" do
              #   name "Search #{humanize(field_name)}"
              #   type :string
              # end
            """

          type when type in [:integer, :decimal] ->
            """
              # deffilter "#{field_name}_range" do
              #   name "#{humanize(field_name)} Range"
              #   type :string
              # end
            """

          _ ->
            """
              # deffilter "custom_filter" do
              #   name "Custom Filter"
              #   type :string
              # end
            """
        end

      _ ->
        """
          # deffilter "custom_filter" do
          #   name "Custom Filter"
          #   type :string
          # end
        """
    end
    |> String.trim_trailing()
  end

  defp generate_query_member_examples_dsl do
    """

      # Optional named query members (used by Selecto.with_cte/2, with_values/2,
      # with_subquery/2, with_lateral/2, and with_unnest/2)
      # defcte :active_rows do
      #   query &__MODULE__.active_rows_cte/1
      #   columns ["id"]
      #   join [owner_key: :id, related_key: :id, fields: :infer]
      # end

      # defvalues :status_lookup do
      #   rows [["active", "Active"], ["inactive", "Inactive"]]
      #   columns ["status", "label"]
      #   as "status_lookup"
      #   join [owner_key: :status, related_key: :status]
      # end

      # defsubquery :high_value_rows do
      #   query &__MODULE__.high_value_rows_subquery/1
      #   type :inner
      #   on [%{left: "id", right: "entity_id"}]
      # end

      # deflateral :recent_series do
      #   source {:function, :generate_series, [1, 3]}
      #   as "recent_series"
      #   join_type :inner
      # end

      # defunnest :tag_values do
      #   array_field "tags"
      #   as "tag_value"
      #   ordinality "tag_position"
      # end
    """
    |> String.trim_trailing()
  end

  defp humanize(atom_or_string) do
    atom_or_string
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp generate_jsonb_schema_examples(config) do
    columns = extract_columns(config)
    field_types = extract_field_types(config)

    jsonb_columns =
      field_types
      |> Enum.filter(fn {_field, col_type} ->
        type = column_type(col_type, columns)
        type in [:jsonb, :map]
      end)
      |> Enum.map(fn {field_name, _} -> field_name end)

    if Enum.empty?(jsonb_columns) do
      ""
    else
      examples =
        jsonb_columns
        |> Enum.map(&generate_jsonb_schema_example/1)
        |> Enum.join("\n\n")

      """

        # JSONB Schema Definitions
      #{examples}
      """
    end
  end

  defp generate_jsonb_schema_example(field_name) do
    """
      # defjsonb_schema :#{field_name} do
      #   %{
      #     "key" => %{type: :string, required: true},
      #     "value" => %{type: :string}
      #   }
      # end
    """
    |> String.trim_trailing()
  end

  defp extract_columns(config) when is_map(config) do
    source_columns =
      case Map.get(config, :source) do
        source when is_map(source) -> Map.get(source, :columns)
        _ -> nil
      end

    source_columns || Map.get(config, :columns) || %{}
  end

  defp extract_columns(_), do: %{}

  defp extract_field_types(config) when is_map(config) do
    Map.get(config, :field_types) || %{}
  end

  defp extract_field_types(_), do: %{}

  defp column_type(col_type, _columns) when is_atom(col_type), do: col_type

  defp column_type(col_type, _columns) when is_map(col_type) do
    Map.get(col_type, :type) || Map.get(col_type, "type") || :string
  end

  defp column_type(field_name, columns) when is_atom(field_name) do
    case Map.get(columns, field_name) do
      %{type: type} -> type
      type when is_atom(type) -> type
      _ -> :string
    end
  end

  defp column_type(_other, _columns), do: :string
end
