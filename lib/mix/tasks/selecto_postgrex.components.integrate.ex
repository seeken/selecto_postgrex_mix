defmodule Mix.Tasks.SelectoPostgrex.Components.Integrate do
  @shortdoc "Integrate SelectoComponents hooks and styles into your Phoenix app"
  @moduledoc """
  Automatically configures SelectoComponents JavaScript hooks and Tailwind styles in
  your Phoenix application.

  This task patches your `app.js` and `app.css` files to include:
  - SelectoComponents colocated JavaScript hooks
  - Tailwind CSS @source directive for SelectoComponents styles

  ## Usage

      mix selecto_postgrex.components.integrate

  ## Options

    * `--check` - Check if integration is needed without making changes
    * `--force` - Force re-integration even if already configured
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [check: :boolean, force: :boolean])

    check_package_json(opts)
    selecto_hooks_status = ensure_selecto_hooks_file(opts)
    app_js_status = integrate_app_js(opts)
    app_css_status = integrate_app_css(opts)

    if opts[:check] do
      report_check_status(selecto_hooks_status, app_js_status, app_css_status)
    else
      report_apply_status(selecto_hooks_status, app_js_status, app_css_status)
    end
  end

  defp check_package_json(opts) do
    package_json_path = "assets/package.json"
    check_only? = opts[:check] == true

    if File.exists?(package_json_path) do
      case File.read(package_json_path) do
        {:ok, content} ->
          needs_chart = !String.contains?(content, "\"chart.js\"")
          needs_alpine = !String.contains?(content, "\"alpinejs\"")

          if needs_chart or needs_alpine do
            if check_only? do
              if needs_chart, do: Mix.shell().info("Chart.js missing from package.json")
              if needs_alpine, do: Mix.shell().info("Alpine.js missing from package.json")
            else
              add_package_deps(package_json_path, content, needs_chart, needs_alpine)
            end
          end

        _ ->
          :ok
      end
    else
      if check_only? do
        Mix.shell().info("assets/package.json missing (would create with Chart.js + Alpine.js)")
      else
        create_package_json(package_json_path)
      end
    end
  end

  defp create_package_json(path) do
    content = """
    {
      "name": "assets",
      "version": "1.0.0",
      "private": true,
      "dependencies": {
        "chart.js": "^4.4.0",
        "alpinejs": "^3.13.0"
      }
    }
    """

    File.write!(path, content)
    Mix.shell().info("Created package.json with Chart.js and Alpine.js dependencies")
  end

  defp add_package_deps(path, content, needs_chart, needs_alpine) do
    case Jason.decode(content) do
      {:ok, json} ->
        deps = Map.get(json, "dependencies", %{})
        deps = if needs_chart, do: Map.put(deps, "chart.js", "^4.4.0"), else: deps
        deps = if needs_alpine, do: Map.put(deps, "alpinejs", "^3.13.0"), else: deps

        updated_json = Map.put(json, "dependencies", deps)

        case Jason.encode(updated_json, pretty: true) do
          {:ok, new_content} -> File.write!(path, new_content)
          _ -> Mix.shell().error("Could not update package.json automatically")
        end

      _ ->
        Mix.shell().error("Could not parse package.json")
    end
  end

  defp integrate_app_js(opts) do
    app_js_path = "assets/js/app.js"

    case File.read(app_js_path) do
      {:ok, content} ->
        already_configured? =
          String.contains?(content, "phoenix-colocated/selecto_components") and
            String.contains?(content, "...selectoComponentsHooks")

        cond do
          already_configured? and !opts[:force] ->
            :already_configured

          opts[:check] ->
            :needs_update

          true ->
            updated =
              content
              |> ensure_selecto_imports()
              |> ensure_livesocket_hooks()

            if updated != content do
              File.write!(app_js_path, updated)
              :updated
            else
              :already_configured
            end
        end

      {:error, :enoent} ->
        :not_found

      {:error, _reason} ->
        :error
    end
  end

  defp ensure_selecto_imports(content) do
    imports = missing_imports(content)

    if imports == [] do
      content
    else
      import_block = Enum.join(imports, "\n")

      cond do
        String.contains?(content, "import {LiveSocket}") ->
          String.replace(
            content,
            ~r/(import {LiveSocket} from "phoenix_live_view")/,
            "\\1\n#{import_block}"
          )

        String.contains?(content, "import") ->
          lines = String.split(content, "\n")
          last_import = lines |> Enum.filter(&String.starts_with?(&1, "import")) |> List.last()

          if is_binary(last_import) do
            String.replace(content, last_import, last_import <> "\n" <> import_block)
          else
            import_block <> "\n" <> content
          end

        true ->
          import_block <> "\n" <> content
      end
    end
  end

  defp missing_imports(content) do
    []
    |> maybe_add_import(
      content,
      "selectoComponentsHooks",
      "import {hooks as selectoComponentsHooks} from \"phoenix-colocated/selecto_components\""
    )
    |> maybe_add_import(content, "TreeBuilderHook", tree_builder_import())
    |> maybe_add_import(content, "selectoHooks", "import selectoHooks from \"./selecto_hooks\"")
    |> maybe_add_chart_import(content)
    |> maybe_add_alpine_import(content)
    |> Enum.reverse()
  end

  defp maybe_add_import(acc, content, marker, import_line) do
    if String.contains?(content, marker), do: acc, else: [import_line | acc]
  end

  defp maybe_add_chart_import(acc, content) do
    if String.contains?(content, "window.Chart") do
      acc
    else
      ["import Chart from \"chart.js/auto\"\nwindow.Chart = Chart" | acc]
    end
  end

  defp maybe_add_alpine_import(acc, content) do
    if String.contains?(content, "window.Alpine") do
      acc
    else
      ["import Alpine from \"alpinejs\"\nwindow.Alpine = Alpine\nAlpine.start()" | acc]
    end
  end

  defp ensure_livesocket_hooks(content) do
    cond do
      String.contains?(content, "hooks:") and
        String.contains?(content, "TreeBuilder: TreeBuilderHook") and
        String.contains?(content, "...selectoComponentsHooks") and
          String.contains?(content, "...selectoHooks") ->
        content

      String.contains?(content, "hooks:") ->
        Regex.replace(~r/hooks:\s*{([^}]*)}/, content, fn _full, hooks_body ->
          existing = hooks_body |> String.trim() |> String.trim_trailing(",")

          additions =
            ""
            |> maybe_append(existing, "TreeBuilder: TreeBuilderHook")
            |> maybe_append(existing, "...selectoComponentsHooks")
            |> maybe_append(existing, "...selectoHooks")

          merged = merge_hooks(existing, additions)
          "hooks: {#{merged}}"
        end)

      String.contains?(content, "new LiveSocket") ->
        String.replace(
          content,
          ~r/(const liveSocket = new LiveSocket\([^,]+,\s*Socket,\s*{)([^}]*)(})/,
          "\\1\\2,\n  hooks: { TreeBuilder: TreeBuilderHook, ...selectoComponentsHooks, ...selectoHooks }\\3"
        )

      true ->
        content
    end
  end

  defp maybe_append(acc, existing, entry) do
    if String.contains?(existing, entry) do
      acc
    else
      if acc == "", do: entry, else: acc <> ", " <> entry
    end
  end

  defp merge_hooks("", additions), do: additions
  defp merge_hooks(existing, ""), do: existing
  defp merge_hooks(existing, additions), do: existing <> ", " <> additions

  defp integrate_app_css(opts) do
    app_css_path = "assets/css/app.css"

    case File.read(app_css_path) do
      {:ok, content} ->
        already_configured? = String.contains?(content, "selecto_components/lib")

        cond do
          already_configured? and !opts[:force] ->
            :already_configured

          opts[:check] ->
            :needs_update

          true ->
            source_line = "@source \"#{selecto_components_path()}\";"

            updated =
              if String.contains?(content, "@source") do
                lines = String.split(content, "\n")

                source_indices =
                  lines
                  |> Enum.with_index()
                  |> Enum.filter(fn {line, _idx} -> String.contains?(line, "@source") end)
                  |> Enum.map(fn {_line, idx} -> idx end)

                case source_indices do
                  [] ->
                    content <> "\n" <> source_line <> "\n"

                  indices ->
                    lines
                    |> List.insert_at(List.last(indices) + 1, source_line)
                    |> Enum.join("\n")
                end
              else
                content <> "\n\n/* SelectoComponents styles */\n" <> source_line <> "\n"
              end

            if updated != content do
              File.write!(app_css_path, updated)
              :updated
            else
              :failed
            end
        end

      {:error, :enoent} ->
        :not_found

      {:error, _reason} ->
        :error
    end
  end

  defp ensure_selecto_hooks_file(opts) do
    hooks_path = "assets/js/selecto_hooks.js"

    cond do
      File.exists?(hooks_path) ->
        :already_configured

      opts[:check] ->
        :needs_update

      true ->
        File.mkdir_p!(Path.dirname(hooks_path))

        content = """
        const selectoHooks = {}

        export default selectoHooks
        """

        File.write!(hooks_path, content)
        :updated
    end
  end

  defp report_check_status(hooks_status, js_status, css_status) do
    Mix.shell().info("Integration status check")
    Mix.shell().info("selecto_hooks.js: #{status_text(hooks_status)}")
    Mix.shell().info("app.js: #{status_text(js_status)}")
    Mix.shell().info("app.css: #{status_text(css_status)}")
  end

  defp report_apply_status(hooks_status, js_status, css_status) do
    Mix.shell().info("Integration results")
    Mix.shell().info("selecto_hooks.js: #{status_text(hooks_status)}")
    Mix.shell().info("app.js: #{status_text(js_status)}")
    Mix.shell().info("app.css: #{status_text(css_status)}")
    Mix.shell().info("Next: run `cd assets && npm install` and `mix assets.build`")
  end

  defp status_text(:already_configured), do: "already configured"
  defp status_text(:needs_update), do: "needs update"
  defp status_text(:updated), do: "updated"
  defp status_text(:not_found), do: "not found"
  defp status_text(:failed), do: "failed"
  defp status_text(_), do: "error"

  defp tree_builder_import do
    "import TreeBuilderHook from \"#{selecto_components_js_base_path()}/lib/selecto_components/components/tree_builder.hooks\""
  end

  defp selecto_components_js_base_path do
    vendor_path = Path.join([File.cwd!(), "vendor", "selecto_components"])
    deps_path = Path.join([File.cwd!(), "deps", "selecto_components"])

    cond do
      File.dir?(vendor_path) -> "../../vendor/selecto_components"
      File.dir?(deps_path) -> "../../deps/selecto_components"
      true -> "../../deps/selecto_components"
    end
  end

  defp selecto_components_path do
    vendor_path = Path.join([File.cwd!(), "vendor", "selecto_components"])
    deps_path = Path.join([File.cwd!(), "deps", "selecto_components"])

    cond do
      File.dir?(vendor_path) -> "../../vendor/selecto_components/lib/**/*.{ex,heex}"
      File.dir?(deps_path) -> "../../deps/selecto_components/lib/**/*.{ex,heex}"
      true -> "../../deps/selecto_components/lib/**/*.{ex,heex}"
    end
  end
end
