defmodule Buffer.Read do
  use GenServer

  @update_fun :on_element_updated
  @compare_fun :updated?

  defmacro __using__(opts \\ []) do
    quote do
      @behaviour unquote(__MODULE__)

      def worker do
        import Supervisor.Spec

        state = %{
          name: __MODULE__,
          interval: unquote(opts[:interval]),
          read: &read/0,
          update: function_exported?(__MODULE__, unquote(@update_fun), 1),
          compare: function_exported?(__MODULE__, unquote(@compare_fun), 2),
          behavior: unquote(opts[:behavior])
        }

        worker(unquote(__MODULE__), [state], id: __MODULE__)
      end

      def timeout, do: unquote(if is_nil(opts[:timeout]), do: 5_000, else: opts[:timeout])

      def synchronize,
        do: unquote(if is_nil(opts[:synchronize]), do: false, else: opts[:synchronize])

      def get(key), do: unquote(__MODULE__).get(__MODULE__, key)
      def select(match_spec), do: unquote(__MODULE__).select(__MODULE__, match_spec)
      def select(match_spec, limit), do: unquote(__MODULE__).select(__MODULE__, match_spec, limit)
      def sync(), do: unquote(__MODULE__).sync(__MODULE__)
      def dump_table(), do: unquote(__MODULE__).dump_table(__MODULE__)
      def reset(), do: unquote(__MODULE__).reset(__MODULE__)
    end
  end

  @doc "Read function"
  @callback read() :: [{key :: any(), element :: any()}]

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: state.name)
  end

  def sync(name) do
    GenServer.call(name, :sync, name.timeout)
  end

  def init(state) do
    :ets.new(state.name, [:public, :set, :named_table, {:read_concurrency, true}])
    Process.send_after(self(), :sync, 0)
    {:ok, state}
  end

  def get(name, key) do
    get(name, key, name.synchronize)
  end

  def get(name, key, synchronize) do
    case :ets.lookup(name, key) do
      [{_, value}] ->
        value

      _ ->
        if synchronize do
          sync(name)
          get(name, key, false)
        else
          nil
        end
    end
  end

  def dump_table(name), do: :ets.tab2list(name)
  def reset(name), do: :ets.delete_all_objects(name)

  def select(name, match_spec), do: :ets.select(name, match_spec)

  def select(name, match_spec, limit) do
    :ets.select(name, match_spec, limit)
  end

  def delete(name, key) do
    :ets.delete(name, key)
  end

  def handle_call(:sync, _, state) do
    read(state)
    {:reply, :ok, state}
  end

  def handle_info(:sync, state) do
    unless is_nil(state.interval) do
      Process.send_after(self(), :sync, state.interval)
    end

    read(state)
    {:noreply, state}
  end

  defp read(state) do
    elements = state.read.()

    if state.behavior == :delete do
      match_spec = [{{:"$1", :_}, [], [:"$1"]}]
      old_ids = select(state.name, match_spec)
      new_ids = Enum.map(elements, fn {id, _} -> id end)
      for id <- old_ids -- new_ids, do: delete(state.name, id)
    end

    updated_ids =
      if state.update do
        Enum.reduce(elements, [], fn {id, element}, acc ->
          previous_element = get(state.name, id, false)
          # Check if the item has been updated using the custom compare function
          is_updated =
            if state.compare do
              apply(state.name, @compare_fun, [previous_element, element])
            else
              # Default behavior if no custom compare function is declared
              element != previous_element
            end

          if is_updated, do: [id | acc], else: acc
        end)
      end

    :ets.insert(state.name, elements)

    unless updated_ids == [] or updated_ids == nil do
      apply(state.name, @update_fun, [updated_ids])
    end
  end
end
