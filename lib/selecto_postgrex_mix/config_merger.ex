defmodule SelectoPostgrexMix.ConfigMerger do
  @moduledoc """
  Merges new table introspection data with existing user customizations.

  Intelligently combines freshly introspected table data with existing domain
  configurations, preserving user customizations while incorporating new
  fields, associations, and other schema changes.
  """

  @doc """
  Merge new domain configuration with existing file content.
  """
  def merge_with_existing(new_config, existing_content) do
    case existing_content do
      nil ->
        new_config

      content when is_binary(content) ->
        existing_config = parse_existing_config(content)
        merge_configurations(new_config, existing_config)
    end
  end

  @doc """
  Parse an existing domain file to extract configuration and customizations.
  """
  def parse_existing_config(file_content) do
    try do
      config = extract_domain_config_from_content(file_content)

      %{
        domain_config: config,
        custom_fields: extract_custom_fields(file_content),
        custom_filters: extract_custom_filters(file_content),
        custom_joins: extract_custom_joins(file_content),
        custom_metadata: extract_custom_metadata(file_content),
        has_customizations: detect_customizations(file_content),
        original_content: file_content
      }
    rescue
      error ->
        %{
          error: "Failed to parse existing config: #{inspect(error)}",
          has_customizations: true,
          original_content: file_content
        }
    end
  end

  @doc """
  Merge two configuration maps intelligently.
  """
  def merge_configurations(new_config, existing_config) do
    if existing_config[:error] || existing_config[:has_customizations] do
      merge_conservatively(new_config, existing_config)
    else
      merge_aggressively(new_config, existing_config)
    end
  end

  @doc """
  Generate a backup of the existing file before major changes.
  """
  def create_backup_if_needed(file_path, existing_content, new_config) do
    if should_create_backup?(existing_content, new_config) do
      backup_path = "#{file_path}.backup.#{timestamp()}"
      File.write!(backup_path, existing_content)
      {:ok, backup_path}
    else
      :no_backup_needed
    end
  end

  # Private functions for parsing existing files

  defp extract_domain_config_from_content(content) do
    config = %{}

    config =
      if table_match = Regex.run(~r/source_table:\s*"([^"]+)"/, content) do
        Map.put(config, :table_name, Enum.at(table_match, 1))
      else
        config
      end

    config =
      if pk_match = Regex.run(~r/primary_key:\s*:(\w+)/, content) do
        Map.put(config, :primary_key, String.to_atom(Enum.at(pk_match, 1)))
      else
        config
      end

    config =
      if fields_match = Regex.run(~r/fields:\s*\[(.*?)\]/s, content) do
        fields_str = Enum.at(fields_match, 1)
        fields = parse_fields_list(fields_str)
        Map.put(config, :fields, fields)
      else
        config
      end

    config
  end

  defp parse_fields_list(fields_str) do
    fields_str
    |> String.split(",")
    |> Enum.map(fn field ->
      field
      |> String.trim()
      |> String.replace(":", "")
    end)
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(&String.to_atom/1)
  end

  defp extract_custom_fields(content) do
    custom_markers = [
      ~r/# CUSTOM FIELD: (.+)/,
      ~r/# User added: (.+)/,
      ~r/# Custom: (.+)/
    ]

    Enum.flat_map(custom_markers, fn regex ->
      Regex.scan(regex, content, capture: :all_but_first)
      |> List.flatten()
    end)
  end

  defp extract_custom_filters(content) do
    filter_matches = Regex.scan(~r/"([^"]+)"\s*=>\s*%\{[^}]*# CUSTOM/, content)

    Enum.into(filter_matches, %{}, fn [_, filter_name] ->
      {filter_name, :custom}
    end)
  end

  defp extract_custom_joins(content) do
    join_matches = Regex.scan(~r/(\w+):\s*%\{[^}]*# CUSTOM JOIN/, content)

    Enum.map(join_matches, fn [_, join_name] ->
      String.to_atom(join_name)
    end)
  end

  defp extract_custom_metadata(content) do
    metadata = %{}

    metadata =
      if name_match = Regex.run(~r/name:\s*"([^"]+)".*# CUSTOM/, content) do
        Map.put(metadata, :custom_name, Enum.at(name_match, 1))
      else
        metadata
      end

    metadata =
      if default_match = Regex.run(~r/default_selected:\s*\[(.*?)\].*# CUSTOM/s, content) do
        defaults = parse_fields_list(Enum.at(default_match, 1))
        Map.put(metadata, :custom_defaults, defaults)
      else
        metadata
      end

    metadata
  end

  defp detect_customizations(content) do
    custom_markers = [
      "# CUSTOM",
      "# User added",
      "# Modified by user",
      "# Custom configuration",
      "# TODO",
      "# FIXME",
      "# NOTE"
    ]

    Enum.any?(custom_markers, &String.contains?(content, &1))
  end

  defp merge_conservatively(new_config, existing_config) do
    base_config = existing_config[:domain_config] || %{}

    new_config
    |> Map.put(:preserve_existing, true)
    |> Map.put(:merge_strategy, :conservative)
    |> Map.merge(%{
      fields:
        merge_fields_conservatively(
          new_config[:fields] || [],
          base_config[:fields] || []
        ),
      associations:
        merge_associations_conservatively(
          new_config[:associations] || %{},
          existing_config[:custom_joins] || []
        ),
      custom_metadata: existing_config[:custom_metadata] || %{},
      custom_fields: existing_config[:custom_fields] || [],
      custom_filters: existing_config[:custom_filters] || %{}
    })
  end

  defp merge_aggressively(new_config, existing_config) do
    new_config
    |> Map.put(:merge_strategy, :aggressive)
    |> Map.merge(%{
      fields:
        merge_fields_aggressively(
          new_config[:fields] || [],
          existing_config[:custom_fields] || []
        ),
      associations:
        merge_associations_aggressively(
          new_config[:associations] || %{},
          existing_config[:custom_joins] || []
        ),
      preserved_customizations: %{
        custom_metadata: existing_config[:custom_metadata] || %{},
        custom_fields: existing_config[:custom_fields] || [],
        custom_filters: existing_config[:custom_filters] || %{}
      }
    })
  end

  defp merge_fields_conservatively(new_fields, existing_fields) do
    existing_field_atoms = Enum.map(existing_fields, &ensure_atom/1)
    new_field_atoms = Enum.map(new_fields, &ensure_atom/1)

    existing_field_atoms ++
      Enum.reject(new_field_atoms, &(&1 in existing_field_atoms))
  end

  defp merge_fields_aggressively(new_fields, custom_fields) do
    custom_field_atoms = Enum.map(custom_fields, &parse_custom_field/1)
    new_field_atoms = Enum.map(new_fields, &ensure_atom/1)

    (new_field_atoms ++ custom_field_atoms) |> Enum.uniq()
  end

  defp merge_associations_conservatively(new_assocs, existing_custom_joins) do
    existing_joins = MapSet.new(existing_custom_joins)

    Enum.reject(new_assocs, fn {assoc_name, _assoc_config} ->
      assoc_name in existing_joins
    end)
    |> Enum.into(new_assocs)
  end

  defp merge_associations_aggressively(new_assocs, existing_custom_joins) do
    custom_joins = MapSet.new(existing_custom_joins)

    Enum.into(new_assocs, %{}, fn {assoc_name, assoc_config} ->
      if assoc_name in custom_joins do
        {assoc_name, Map.put(assoc_config, :is_custom, true)}
      else
        {assoc_name, assoc_config}
      end
    end)
  end

  defp ensure_atom(field) when is_atom(field), do: field
  defp ensure_atom(field) when is_binary(field), do: String.to_atom(field)
  defp ensure_atom(field), do: field

  defp parse_custom_field(custom_field_desc) when is_binary(custom_field_desc) do
    custom_field_desc
    |> String.split()
    |> List.first()
    |> String.to_atom()
  rescue
    _ -> :unknown_custom_field
  end

  defp should_create_backup?(existing_content, new_config) do
    has_customizations = detect_customizations(existing_content || "")
    aggressive_merge = new_config[:merge_strategy] == :aggressive

    has_customizations and aggressive_merge
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_unix()
    |> to_string()
  end
end
