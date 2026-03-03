defmodule Mix.Tasks.SelectoPostgrex.AddTimeouts do
  @shortdoc "Add query timeout defense system for Postgrex connections"
  @moduledoc """
  Adds a multi-layer query timeout defense system to protect your database from overload.

  This task implements a comprehensive defense strategy including:
  - PostgreSQL statement_timeout configuration
  - Postgrex connection pool timeout configuration
  - QueryTimeoutMonitor with circuit breaker pattern
  - Application supervision tree integration

  ## Examples

      # Add with default settings (30s timeout, 90% circuit breaker threshold)
      mix selecto_postgrex.add_timeouts MyApp

      # Add with custom timeout
      mix selecto_postgrex.add_timeouts MyApp --timeout 60000

      # Add with custom circuit breaker threshold
      mix selecto_postgrex.add_timeouts MyApp --circuit-threshold 0.8

      # Preview changes without applying
      mix selecto_postgrex.add_timeouts MyApp --dry-run

  ## Options

    * `--timeout` - Default query timeout in milliseconds (default: 30000)
    * `--test-timeout` - Test query timeout in milliseconds (default: 15000)
    * `--pool-size` - Connection pool size (default: 10)
    * `--circuit-threshold` - Pool utilization threshold to open circuit (default: 0.9)
    * `--check-interval` - Health check interval in milliseconds (default: 5000)
    * `--connection-name` - Named Postgrex connection (default: APP.Database)
    * `--dry-run` - Show what would be changed without applying
    * `--force` - Overwrite existing QueryTimeoutMonitor module
    * `--skip-config` - Compatibility flag (Postgrex task prints config instructions only)
    * `--skip-monitor` - Skip QueryTimeoutMonitor generation
    * `--skip-supervision` - Compatibility flag (task prints supervision instructions)

  ## What Gets Generated

  - `lib/APP_NAME/query_timeout_monitor.ex` - Circuit breaker GenServer
  - Prints instructions for configuring Postgrex child spec with timeouts

  ## Defense Layers

  The system implements multiple defense layers:

  1. **PostgreSQL Level**: `statement_timeout` kills queries at database
  2. **Postgrex Level**: Connection pool timeouts (query, connect, queue)
  3. **Application Level**: Task-based timeout wrapper
  4. **Circuit Breaker**: Blocks queries when pool saturated

  ## Environment Variables (Production)

  Set these in your production environment:

      QUERY_TIMEOUT=30000          # Query execution timeout
      STATEMENT_TIMEOUT=30000      # PostgreSQL statement timeout
      POOL_SIZE=10                 # Connection pool size
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :selecto,
      example: "mix selecto_postgrex.add_timeouts MyApp --timeout 60000",
      positional: [:app_name],
      schema: [
        timeout: :integer,
        test_timeout: :integer,
        pool_size: :integer,
        circuit_threshold: :float,
        check_interval: :integer,
        connection_name: :string,
        dry_run: :boolean,
        force: :boolean,
        skip_config: :boolean,
        skip_monitor: :boolean,
        skip_supervision: :boolean
      ],
      aliases: [
        t: :timeout,
        d: :dry_run,
        f: :force
      ],
      defaults: [
        timeout: 30_000,
        test_timeout: 15_000,
        pool_size: 10,
        circuit_threshold: 0.9,
        check_interval: 5_000,
        dry_run: false,
        force: false,
        skip_config: false,
        skip_monitor: false,
        skip_supervision: false
      ]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    parsed_args = igniter.args.options
    positional = igniter.args.positional
    app_name_arg = Map.get(positional, :app_name)

    if is_nil(app_name_arg) or app_name_arg == "" do
      Igniter.add_warning(igniter, """
      App name is required. Usage:
        mix selecto_postgrex.add_timeouts MyApp
      """)
    else
      generate(igniter, app_name_arg, parsed_args)
    end
  end

  defp generate(igniter, app_name, opts) do
    config = build_config(app_name, opts)
    igniter = add_compatibility_notices(igniter, opts)

    if opts[:dry_run] do
      show_dry_run(config)
      igniter
    else
      igniter
      |> maybe_generate_monitor(config, opts)
      |> add_success_messages(config, opts)
    end
  end

  defp build_config(app_name, opts) do
    %{
      app_name: app_name,
      app_underscore: Macro.underscore(app_name),
      connection_name: opts[:connection_name] || "#{app_name}.Database",
      timeout: opts[:timeout] || 30_000,
      test_timeout: opts[:test_timeout] || 15_000,
      pool_size: opts[:pool_size] || 10,
      circuit_threshold: opts[:circuit_threshold] || 0.9,
      check_interval: opts[:check_interval] || 5_000,
      force: opts[:force] || false
    }
  end

  defp show_dry_run(config) do
    IO.puts("""

    SelectoPostgrex Timeout Defense System (DRY RUN)
    =================================================

    Files to be generated:
      * lib/#{config.app_underscore}/query_timeout_monitor.ex

    Configuration:
      * Query timeout: #{config.timeout}ms
      * Test timeout: #{config.test_timeout}ms
      * Pool size: #{config.pool_size}
      * Circuit breaker threshold: #{Float.round(config.circuit_threshold * 100, 1)}%
      * Check interval: #{config.check_interval}ms
      * Connection name: #{config.connection_name}

    Run without --dry-run to generate files.
    """)
  end

  defp add_compatibility_notices(igniter, opts) do
    igniter
    |> maybe_add_notice(
      opts[:skip_config],
      "--skip-config has no effect in Postgrex mode (config is not edited automatically)"
    )
    |> maybe_add_notice(
      opts[:skip_supervision],
      "--skip-supervision has no effect in Postgrex mode (supervision is not edited automatically)"
    )
  end

  defp maybe_add_notice(igniter, true, message), do: Igniter.add_notice(igniter, message)
  defp maybe_add_notice(igniter, _flag, _message), do: igniter

  defp maybe_generate_monitor(igniter, config, opts) do
    if opts[:skip_monitor] do
      Igniter.add_notice(igniter, "Skipped QueryTimeoutMonitor generation (--skip-monitor)")
    else
      generate_monitor(igniter, config)
    end
  end

  defp generate_monitor(igniter, config) do
    file_path = "lib/#{config.app_underscore}/query_timeout_monitor.ex"

    content = """
    defmodule #{config.app_name}.QueryTimeoutMonitor do
      @moduledoc \"\"\"
      Monitors database query performance and implements circuit breaker pattern
      for Postgrex connections.

      Circuit breaker states:
      - `:closed` - Normal operation, queries allowed
      - `:open` - System overloaded, queries blocked
      - `:half_open` - Testing if system has recovered

      ## Configuration

      Add to your supervision tree after the Postgrex child:

          children = [
            {Postgrex, name: #{config.connection_name}, ...},
            #{config.app_name}.QueryTimeoutMonitor
          ]

      ## Usage

          # Check if queries are allowed
          #{config.app_name}.QueryTimeoutMonitor.allow_query?()

          # Get current statistics
          #{config.app_name}.QueryTimeoutMonitor.stats()

          # Record query metrics
          #{config.app_name}.QueryTimeoutMonitor.record_query(duration_ms)
          #{config.app_name}.QueryTimeoutMonitor.record_timeout()

      Generated by: mix selecto_postgrex.add_timeouts
      \"\"\"

      use GenServer

      @check_interval #{config.check_interval}
      @circuit_open_threshold #{config.circuit_threshold}
      @circuit_half_open_timeout 30_000
      @slow_query_threshold 10_000
      @very_slow_query_threshold 30_000

      defstruct [
        circuit_state: :closed,
        total_queries: 0,
        slow_queries: 0,
        very_slow_queries: 0,
        timeouts: 0,
        last_timeout_at: nil,
        circuit_opened_at: nil,
        pool_size: #{config.pool_size}
      ]

      # Client API

      def start_link(opts \\\\\\\\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def allow_query? do
        GenServer.call(__MODULE__, :allow_query?)
      end

      def circuit_state do
        GenServer.call(__MODULE__, :circuit_state)
      end

      def stats do
        GenServer.call(__MODULE__, :stats)
      end

      def record_query(duration_ms) do
        GenServer.cast(__MODULE__, {:record_query, duration_ms})
      end

      def record_timeout do
        GenServer.cast(__MODULE__, :record_timeout)
      end

      def record_slow_query(duration_ms) do
        GenServer.cast(__MODULE__, {:record_slow_query, duration_ms})
      end

      # Server Callbacks

      @impl true
      def init(_opts) do
        schedule_check()
        {:ok, %__MODULE__{}}
      end

      @impl true
      def handle_call(:allow_query?, _from, state) do
        allowed = state.circuit_state != :open
        {:reply, allowed, state}
      end

      def handle_call(:circuit_state, _from, state) do
        {:reply, state.circuit_state, state}
      end

      def handle_call(:stats, _from, state) do
        stats = %{
          circuit_state: state.circuit_state,
          total_queries: state.total_queries,
          slow_queries: state.slow_queries,
          very_slow_queries: state.very_slow_queries,
          timeouts: state.timeouts,
          last_timeout_at: state.last_timeout_at,
          circuit_opened_at: state.circuit_opened_at
        }
        {:reply, stats, state}
      end

      @impl true
      def handle_cast({:record_query, duration_ms}, state) do
        state = %{state | total_queries: state.total_queries + 1}

        state =
          cond do
            duration_ms >= @very_slow_query_threshold ->
              %{state | very_slow_queries: state.very_slow_queries + 1, slow_queries: state.slow_queries + 1}

            duration_ms >= @slow_query_threshold ->
              %{state | slow_queries: state.slow_queries + 1}

            true ->
              state
          end

        {:noreply, state}
      end

      def handle_cast(:record_timeout, state) do
        state = %{state |
          timeouts: state.timeouts + 1,
          last_timeout_at: DateTime.utc_now()
        }

        {:noreply, maybe_open_circuit(state)}
      end

      def handle_cast({:record_slow_query, duration_ms}, state) do
        state =
          cond do
            duration_ms >= @very_slow_query_threshold ->
              %{state | very_slow_queries: state.very_slow_queries + 1, slow_queries: state.slow_queries + 1}

            duration_ms >= @slow_query_threshold ->
              %{state | slow_queries: state.slow_queries + 1}

            true ->
              state
          end

        {:noreply, state}
      end

      @impl true
      def handle_info(:check_health, state) do
        state = check_pool_health(state)
        schedule_check()
        {:noreply, state}
      end

      # Private

      defp schedule_check do
        Process.send_after(self(), :check_health, @check_interval)
      end

      defp check_pool_health(state) do
        case state.circuit_state do
          :open ->
            if state.circuit_opened_at &&
               DateTime.diff(DateTime.utc_now(), state.circuit_opened_at, :millisecond) > @circuit_half_open_timeout do
              %{state | circuit_state: :half_open}
            else
              state
            end

          :half_open ->
            # If we haven't had timeouts recently, close the circuit
            if state.last_timeout_at == nil or
               DateTime.diff(DateTime.utc_now(), state.last_timeout_at, :millisecond) > @circuit_half_open_timeout do
              %{state | circuit_state: :closed, circuit_opened_at: nil}
            else
              %{state | circuit_state: :open, circuit_opened_at: DateTime.utc_now()}
            end

          :closed ->
            state
        end
      end

      defp maybe_open_circuit(state) do
        if state.total_queries > 0 do
          timeout_ratio = state.timeouts / state.total_queries
          if timeout_ratio >= @circuit_open_threshold do
            %{state | circuit_state: :open, circuit_opened_at: DateTime.utc_now()}
          else
            state
          end
        else
          state
        end
      end
    end
    """

    if config.force do
      Igniter.create_or_update_file(igniter, file_path, content, fn _ -> content end)
    else
      Igniter.create_new_file(igniter, file_path, content)
    end
  end

  defp add_success_messages(igniter, config, opts) do
    igniter =
      if opts[:skip_monitor] do
        igniter
      else
        Igniter.add_notice(
          igniter,
          "Generated: lib/#{config.app_underscore}/query_timeout_monitor.ex"
        )
      end

    igniter
    |> Igniter.add_notice("""

    Query timeout defense system generated!

    ## Postgrex Child Spec with Timeouts

    Add to your supervision tree in application.ex:

        children = [
          {Postgrex,
            name: #{config.connection_name},
            hostname: "localhost",
            database: "your_db",
            username: "postgres",
            password: "postgres",
            pool_size: #{config.pool_size},
            timeout: #{config.timeout},
            connect_timeout: 5_000,
            queue_target: 5_000,
            queue_interval: 1_000,
            parameters: [
              statement_timeout: "#{config.timeout}",
              idle_in_transaction_session_timeout: "300000"
            ]},
          #{config.app_name}.QueryTimeoutMonitor
        ]

    ## Environment Variables (Production)

        export QUERY_TIMEOUT=#{config.timeout}
        export TEST_QUERY_TIMEOUT=#{config.test_timeout}
        export STATEMENT_TIMEOUT=#{config.timeout}
        export POOL_SIZE=#{config.pool_size}

    ## Usage

        #{config.app_name}.QueryTimeoutMonitor.allow_query?()
        #{config.app_name}.QueryTimeoutMonitor.stats()
        #{config.app_name}.QueryTimeoutMonitor.circuit_state()
    """)
  end
end
