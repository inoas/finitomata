defmodule Finitomata do
  @moduledoc "README.md" |> File.read!() |> String.split("\n---") |> Enum.at(1)

  require Logger
  use Boundary, top_level?: true, deps: [], exports: [Supervisor, Transition]
  alias Finitomata.Transition

  defmodule State do
    @moduledoc """
    Carries the state of the FSM.
    """

    alias Finitomata.Transition

    @typedoc "The payload that has been passed to the FSM instance on startup"
    @type payload :: any()

    @typedoc "The internal representation of the FSM state"
    @type t :: %{
            __struct__: State,
            current: Transition.state(),
            payload: payload(),
            history: [Transition.state()]
          }
    defstruct [:current, :payload, history: []]
  end

  @typedoc "The payload that can be passed to each call to `transition/3`"
  @type event_payload :: any()

  @doc """
  This callback will be called from each transition processor.
  """
  @callback on_transition(
              Transition.state(),
              Transition.event(),
              event_payload(),
              State.payload()
            ) ::
              {:ok, Transition.state(), State.payload()} | :error

  @doc """
  This callback will be called if the transition failed to complete to allow
  the consumer to take an action upon failure.
  """
  @callback on_failure(Transition.event(), event_payload(), State.t()) :: :ok

  @doc """
  This callback will be called on transition to the final state to allow
  the consumer to perform some cleanup, or like.
  """
  @callback on_terminate(State.t()) :: :ok

  @doc """
  Starts the FSM instance.

  The arguments are

  - the implementation of FSM (the module, having `use Finitomata`)
  - the name of the FSM (might be any term, but it must be unique)
  - the payload to be carried in the FSM state during the lifecycle

  The FSM is started supervised.
  """
  @spec start_fsm(module(), any(), any()) :: DynamicSupervisor.on_start_child()
  def start_fsm(impl, name, payload),
    do:
      DynamicSupervisor.start_child(Finitomata.Manager, {impl, name: fqn(name), payload: payload})

  @doc """
  Initiates the transition.

  The arguments are

  - the name of the FSM
  - `{event, event_payload}` tuple; the payload will be passed to the respective
    `on_transition/4` call
  """
  @spec transition(GenServer.name(), {Transition.event(), State.payload()}) :: :ok
  def transition(target, {event, payload}),
    do: target |> fqn() |> GenServer.cast({event, payload})

  @doc """
  The state of the FSM.
  """
  @spec state(GenServer.name()) :: State.t()
  def state(target), do: target |> fqn() |> GenServer.call(:state)

  @doc """
  Returns `true` if the transition to the state `state` is possible, `false` otherwise.
  """
  @spec allowed?(GenServer.name(), Transition.state()) :: boolean()
  def allowed?(target, state), do: target |> fqn() |> GenServer.call({:allowed?, state})

  @doc """
  Returns `true` if the transition by the event `event` is possible, `false` otherwise.
  """
  @spec responds?(GenServer.name(), Transition.event()) :: boolean()
  def responds?(target, event), do: target |> fqn() |> GenServer.call({:responds?, event})

  @doc """
  Returns `true` if the supervision tree is alive, `false` otherwise.
  """
  @spec alive? :: boolean()
  def alive?, do: is_pid(Process.whereis(Registry.Finitomata))

  @doc """
  Returns `true` if the FSM specified is alive, `false` otherwise.
  """
  @spec alive?(GenServer.name()) :: boolean()
  def alive?(target), do: target |> fqn() |> GenServer.whereis() |> is_pid()

  @doc false
  @spec child_spec(non_neg_integer()) :: Supervisor.child_spec()
  def child_spec(id \\ 0),
    do: Supervisor.child_spec({Finitomata.Supervisor, []}, id: {Finitomata, id})

  @doc false
  defmacro __using__(plant) do
    quote location: :keep, generated: true do
      require Logger
      alias Finitomata.Transition, as: Transition
      use GenServer, restart: :transient, shutdown: 5_000

      @before_compile Finitomata.Hook

      @plant (case Finitomata.PlantUML.parse(unquote(plant)) do
                {:ok, result} ->
                  result

                {:error, description, snippet, _, {line, column}, _} ->
                  raise SyntaxError,
                    file: "lib/finitomata.ex",
                    line: line,
                    column: column,
                    description: description,
                    snippet: %{content: snippet, offset: 0}

                {:error, error} ->
                  raise TokenMissingError,
                    description: "description is incomplete, error: #{error}"
              end)

      @doc false
      def start_link(payload: payload, name: name),
        do: start_link(name: name, payload: payload)

      @doc ~s"""
      Starts an _FSM_ alone with `name` and `payload` given.

      Usually one does not want to call this directly, the most common way would be
      to start a `Finitomata` supervision tree with `Finitomata.Supervisor.start_link/1`
      or even better embed it into the existing supervision tree _and_
      start _FSM_ with `Finitomata.start_fsm/3` passing `#{__MODULE__}` as the first
      parameter.
      """
      def start_link(name: name, payload: payload),
        do: GenServer.start_link(__MODULE__, payload, name: name)

      @doc false
      @impl GenServer
      def init(payload) do
        # Process.flag(:trap_exit, true)
        {:ok, %State{current: Transition.entry(@plant), payload: payload}}
      end

      @doc false
      @impl GenServer
      def handle_call(:state, _from, state), do: {:reply, state, state}

      @doc false
      @impl GenServer
      def handle_call({:allowed?, to}, _from, state),
        do: {:reply, Transition.allowed?(@plant, state.current, to), state}

      @doc false
      @impl GenServer
      def handle_call({:responds?, event}, _from, state),
        do: {:reply, Transition.responds?(@plant, state.current, event), state}

      @doc false
      @impl GenServer
      def handle_cast({event, payload}, state) do
        with {:ok, new_current, new_payload} <-
               safe_on_transition(state.current, event, payload, state.payload),
             true <- Transition.allowed?(@plant, state.current, new_current) do
          case new_current do
            :* ->
              {:stop, :normal, state}

            _ ->
              {:noreply,
               %State{
                 state
                 | payload: new_payload,
                   current: new_current,
                   history: [state.current | state.history]
               }}
          end
        else
          err ->
            Logger.warn("[⚐ ⇄] transition failed " <> inspect(err))
            safe_on_failure(event, payload, state)
            {:noreply, state}
        end
      end

      @doc false
      @impl GenServer
      def terminate(reason, state) do
        safe_on_terminate(state)
      end

      @spec safe_on_transition(
              Transition.state(),
              Transition.event(),
              Finitomata.event_payload(),
              State.payload()
            ) ::
              {:ok, Transition.state(), State.payload()} | :error
      defp safe_on_transition(current, event, event_payload, state_payload) do
        on_transition(current, event, event_payload, state_payload)
      rescue
        err ->
          case err do
            %{__exception__: true} ->
              {:error, Exception.message(err)}

            _ ->
              Logger.warn("[⚑ ⇄] on_transition raised " <> inspect(err))
              {:error, :on_transition_raised}
          end
      end

      @spec safe_on_failure(Transition.event(), Finitomata.event_payload(), State.t()) :: :ok
      defp safe_on_failure(event, event_payload, state_payload) do
        on_failure(event, event_payload, state_payload)
      rescue
        err -> Logger.warn("[⚑ ⇄] on_failure raised " <> inspect(err))
      end

      @spec safe_on_terminate(State.t()) :: :ok
      defp safe_on_terminate(state) do
        on_terminate(state)
      rescue
        err -> Logger.warn("[⚑ ⇄] on_terminate raised " <> inspect(err))
      end

      @behaviour Finitomata
    end
  end

  @spec fqn(any()) :: {:via, module(), {module, any()}}
  defp fqn(name), do: {:via, Registry, {Registry.Finitomata, name}}
end
