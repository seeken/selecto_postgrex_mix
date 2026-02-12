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
      \"\"\"

      use Selecto.Config.OverlayDSL

      # Uncomment to redact sensitive fields from query results
      #{redaction_example}

      # Uncomment and customize column configurations as needed
    #{column_examples}

      # Uncomment and add custom filters
    #{filter_examples}
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
    columns = get_in(config, [:source, :columns]) || config[:columns] || %{}

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
    columns = get_in(config, [:source, :columns]) || config[:columns] || %{}

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
    type = Map.get(column_config, :type, :string)

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
    columns = get_in(config, [:source, :columns]) || config[:columns] || %{}

    example_field =
      columns
      |> Enum.find(fn {_field, col_config} ->
        Map.get(col_config, :type) in [:string, :integer, :decimal, :boolean]
      end)

    case example_field do
      {field_name, %{type: :string}} ->
        """
          # deffilter "#{field_name}_search" do
          #   name "Search #{humanize(field_name)}"
          #   type :string
          # end
        """

      {field_name, %{type: type}} when type in [:integer, :decimal] ->
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
    columns = get_in(config, [:source, :columns]) || config[:field_types] || %{}

    jsonb_columns =
      columns
      |> Enum.filter(fn {_field, col_config} ->
        type = if is_map(col_config), do: Map.get(col_config, :type), else: col_config
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
end
