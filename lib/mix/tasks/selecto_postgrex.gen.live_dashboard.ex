defmodule Mix.Tasks.SelectoPostgrex.Gen.LiveDashboard do
  @moduledoc """
  Generates a Phoenix LiveDashboard page for Selecto query metrics.

  ## Usage

      mix selecto_postgrex.gen.live_dashboard

  ## Options

    * `--no-router` - Skip router.ex modifications
    * `--module` - The module name for the page (default: YourAppWeb.LiveDashboard.SelectoPage)
  """

  use Mix.Task
  import Mix.Generator

  @shortdoc "Generates a LiveDashboard page for Selecto metrics"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          no_router: :boolean,
          module: :string
        ]
      )

    Mix.Task.run("compile")

    app = Mix.Project.config()[:app]
    app_module = app |> to_string() |> Macro.camelize()
    web_module = Module.concat([app_module, "Web"])

    page_module =
      if opts[:module] do
        Module.concat([opts[:module]])
      else
        Module.concat([web_module, "LiveDashboard", "SelectoPage"])
      end

    generate_page_module(app, page_module)
    add_telemetry_metrics(app)

    unless opts[:no_router] do
      update_router(app, web_module, page_module)
    end

    Mix.shell().info("Generated Selecto LiveDashboard page.")
  end

  defp generate_page_module(app, page_module) do
    path = page_module_path(app, page_module)

    content = ~s'
    defmodule #{page_module} do
      @moduledoc """
      LiveDashboard page for Selecto query metrics.
      """

      use Phoenix.LiveDashboard.PageBuilder
      import Telemetry.Metrics

      @impl true
      def menu_link(_, _) do
        {:ok, "Selecto"}
      end

      @impl true
      def render_page(assigns) do
        items = [
          {:query_metrics, name: "Query Metrics", render: &render_query_metrics/1},
          {:slow_queries, name: "Slow Queries", render: &render_slow_queries/1}
        ]

        nav_bar(items: items)
      end

      defp render_query_metrics(assigns) do
        stats = get_stats()
        assigns = Map.put(assigns, :stats, stats)

        ~H"""
        <div>
          <h2 class="text-xl font-bold mb-4">Selecto Query Metrics</h2>

          <.live_component
            module={Phoenix.LiveDashboard.ChartComponent}
            id="selecto-query-duration"
            title="Query Duration"
            kind={:line}
            label="Duration (ms)"
            prune_threshold={100}
            metric={summary("selecto.query.complete.duration")}
          />

          <div class="grid grid-cols-3 gap-4 mt-6">
            <div class="bg-blue-50 p-4 rounded">
              <div class="text-sm text-gray-600">Total Queries</div>
              <div class="text-2xl font-bold text-blue-700">{@stats.total_queries}</div>
            </div>
            <div class="bg-green-50 p-4 rounded">
              <div class="text-sm text-gray-600">Average Duration</div>
              <div class="text-2xl font-bold text-green-700">{@stats.avg_duration}ms</div>
            </div>
            <div class="bg-yellow-50 p-4 rounded">
              <div class="text-sm text-gray-600">Error Rate</div>
              <div class="text-2xl font-bold text-yellow-700">{@stats.error_rate}%</div>
            </div>
          </div>
        </div>
        """
      end

      defp render_slow_queries(assigns) do
        assigns = Map.put(assigns, :slow_queries, get_slow_queries())

        ~H"""
        <div>
          <h2 class="text-xl font-bold mb-4">Slow Queries</h2>

          <div :if={@slow_queries == []} class="text-gray-500">No slow queries recorded.</div>

          <div :for={q <- @slow_queries} class="mb-4 border rounded p-3 bg-white">
            <div class="text-sm text-gray-500">{q.timestamp}</div>
            <div class="font-semibold">{q.duration_ms}ms</div>
            <pre class="text-xs overflow-x-auto">{q.query}</pre>
          </div>
        </div>
        """
      end

      defp get_stats do
        if Process.whereis(SelectoComponents.Performance.MetricsCollector) do
          metrics = SelectoComponents.Performance.MetricsCollector.get_metrics("1h")

          %{
            total_queries: metrics[:total_queries] || 0,
            avg_duration: metrics[:avg_response_time] || 0,
            error_rate: metrics[:error_rate] || 0
          }
        else
          %{total_queries: 0, avg_duration: 0, error_rate: 0}
        end
      end

      defp get_slow_queries do
        if Process.whereis(SelectoComponents.Performance.MetricsCollector) do
          SelectoComponents.Performance.MetricsCollector.get_slow_queries(500, 20)
          |> Enum.map(fn q ->
            %{
              timestamp: Map.get(q, :timestamp, "n/a"),
              duration_ms: Map.get(q, :execution_time, 0),
              query: Map.get(q, :query, "")
            }
          end)
        else
          []
        end
      end
    end
    '

    create_file(path, content)
  end

  defp add_telemetry_metrics(app) do
    telemetry_path = Path.join(["lib", "#{app}_web", "telemetry.ex"])

    if File.exists?(telemetry_path) do
      content = File.read!(telemetry_path)

      unless String.contains?(content, "selecto.query.complete.duration") do
        updated =
          String.replace(
            content,
            "# VM Metrics",
            """
            # Selecto Metrics
            summary("selecto.query.complete.duration",
              unit: {:native, :millisecond},
              description: "Selecto query execution time"
            ),
            counter("selecto.query.error.count",
              description: "Number of Selecto query errors"
            ),

            # VM Metrics
            """
          )

        File.write!(telemetry_path, updated)
      end
    end
  end

  defp update_router(app, web_module, page_module) do
    router_path = Path.join(["lib", "#{app}_web", "router.ex"])

    if File.exists?(router_path) do
      content = File.read!(router_path)

      unless String.contains?(content, "additional_pages:") do
        updated =
          String.replace(
            content,
            ~r/live_dashboard\s+"\/dashboard",\s*\n\s*metrics:\s*#{web_module}\.Telemetry/,
            """
            live_dashboard "/dashboard",
              metrics: #{web_module}.Telemetry,
              additional_pages: [
                selecto: #{page_module}
              ]
            """
          )

        if updated != content do
          File.write!(router_path, updated)
        else
          Mix.shell().info("Could not auto-update router.ex; add additional_pages manually.")
        end
      end
    end
  end

  defp page_module_path(app, module_name) when is_atom(module_name) do
    parts = Module.split(module_name)
    web_part = Enum.find_index(parts, &(&1 =~ ~r/Web$/i)) || 0

    path_parts =
      parts
      |> Enum.drop(web_part + 1)
      |> Enum.map(&Macro.underscore/1)

    Path.join(["lib", "#{app}_web"] ++ path_parts) <> ".ex"
  end
end
