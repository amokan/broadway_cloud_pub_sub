defmodule BroadwayCloudPubSub.ProducerTest do
  use ExUnit.Case

  alias Broadway.Message
  alias NimbleOptions.ValidationError

  defmodule MessageServer do
    def start_link() do
      Agent.start_link(fn -> [] end)
    end

    def push_messages(server, messages) do
      Agent.update(server, fn queue -> queue ++ messages end)
    end

    def take_messages(server, amount) do
      Agent.get_and_update(server, &Enum.split(&1, amount))
    end
  end

  defmodule FakeClient do
    alias BroadwayCloudPubSub.Client
    alias Broadway.Acknowledger

    @behaviour Client
    @behaviour Acknowledger

    @impl Client
    def init(opts), do: {:ok, opts}

    @impl Client
    def receive_messages(amount, _builder, opts) do
      messages = MessageServer.take_messages(opts[:message_server], amount)
      send(opts[:test_pid], {:messages_received, length(messages)})

      for msg <- messages do
        ack_data = %{
          receipt: %{id: "Id_#{msg}", receipt_handle: "ReceiptHandle_#{msg}"},
          test_pid: opts[:test_pid]
        }

        %Message{data: msg, acknowledger: {__MODULE__, :ack_ref, ack_data}}
      end
    end

    @impl Acknowledger
    def ack(_ack_ref, successful, _failed) do
      [%Message{acknowledger: {_, _, %{test_pid: test_pid}}} | _] = successful
      send(test_pid, {:messages_deleted, length(successful)})
    end
  end

  defmodule FakePool do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end

    def init(opts) do
      send(opts[:test_pid], {:pool_started, opts[:name]})

      {:ok, opts}
    end

    def child_spec(name, opts) do
      {__MODULE__, Keyword.put(opts, :name, name)}
    end

    def pool_size(pool), do: GenServer.call(pool, :pool_size)

    def handle_call(:pool_size, _, opts) do
      {:reply, opts[:pool_size], opts}
    end
  end

  defmodule FakePoolClient do
    alias BroadwayCloudPubSub.Client

    @behaviour Client

    @impl Client
    def prepare_to_connect(module, opts) do
      pool = Module.concat(module, FakePool)
      pool_spec = FakePool.child_spec(pool, opts)

      {[pool_spec], Keyword.put(opts, :__connection_pool__, pool)}
    end

    @impl Client
    def init(opts) do
      send(opts[:test_pid], {:connection_pool_set, opts[:__connection_pool__]})

      {:ok, opts}
    end

    @impl Client
    def receive_messages(_amount, _builder, _opts), do: []
  end

  defmodule Forwarder do
    use Broadway

    def handle_message(_, message, %{test_pid: test_pid}) do
      send(test_pid, {:message_handled, message.data})
      message
    end

    def handle_batch(_, messages, _, _) do
      messages
    end
  end

  defp prepare_for_start_module_opts(module_opts) do
    {:ok, message_server} = MessageServer.start_link()
    {:ok, pid} = start_broadway(message_server)

    try do
      BroadwayCloudPubSub.Producer.prepare_for_start(Forwarder,
        producer: [
          module: {BroadwayCloudPubSub.Producer, module_opts},
          concurrency: 1
        ]
      )
    after
      stop_broadway(pid)
    end
  end

  describe "prepare_for_start/2 validation" do
    test ":subcription should be a string" do
      assert_raise(
        ValidationError,
        "required option :subscription not found, received options: [:client, :pool_size]",
        fn ->
          prepare_for_start_module_opts([])
        end
      )

      assert_raise(
        ValidationError,
        ~r/expected :subscription to be a non-empty string, got: nil/,
        fn ->
          prepare_for_start_module_opts(subscription: nil)
        end
      )

      assert_raise(
        ValidationError,
        ~r/expected :subscription to be a non-empty string, got: \"\"/,
        fn ->
          prepare_for_start_module_opts(subscription: "")
        end
      )

      assert_raise(
        ValidationError,
        ~r/expected :subscription to be a non-empty string, got: :foo/,
        fn ->
          prepare_for_start_module_opts(subscription: :foo)
        end
      )

      assert {
               _,
               [
                 producer: [
                   module: {BroadwayCloudPubSub.Producer, producer_opts},
                   concurrency: 1
                 ]
               ]
             } = prepare_for_start_module_opts(subscription: "projects/foo/subscriptions/bar")

      assert producer_opts[:subscription] == "projects/foo/subscriptions/bar"
    end

    test ":max_number_of_messages is optional with default value 10" do
      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} = prepare_for_start_module_opts(subscription: "projects/foo/subscriptions/bar")

      assert producer_opts[:max_number_of_messages] == 10
    end

    test ":max_number_of_messages should be a positive integer" do
      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, result_module_opts},
                  concurrency: 1
                ]
              ]} =
               prepare_for_start_module_opts(
                 subscription: "projects/foo/subscriptions/bar",
                 max_number_of_messages: 1
               )

      assert result_module_opts[:max_number_of_messages] == 1

      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, result_module_opts},
                  concurrency: 1
                ]
              ]} =
               prepare_for_start_module_opts(
                 subscription: "projects/foo/subscriptions/bar",
                 max_number_of_messages: 10
               )

      assert result_module_opts[:max_number_of_messages] == 10

      assert_raise(
        ValidationError,
        ~r/expected :max_number_of_messages to be a positive integer, got: 0/,
        fn ->
          prepare_for_start_module_opts(
            subscription: "projects/foo/subscriptions/bar",
            max_number_of_messages: 0
          )
        end
      )

      assert_raise(
        ValidationError,
        ~r/expected :max_number_of_messages to be a positive integer, got: -1/,
        fn ->
          prepare_for_start_module_opts(
            subscription: "projects/foo/subscriptions/bar",
            max_number_of_messages: -1
          )
        end
      )
    end

    test ":scope is optional with a default value https://www.googleapis.com/auth/pubsub" do
      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} = prepare_for_start_module_opts(subscription: "projects/foo/subscriptions/bar")

      assert producer_opts[:scope] == "https://www.googleapis.com/auth/pubsub"
    end

    test ":scope should be a string or tuple" do
      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} =
               prepare_for_start_module_opts(
                 subscription: "projects/foo/subscriptions/bar",
                 scope: "https://example.com"
               )

      assert {_, _, ["https://example.com"]} = producer_opts[:token_generator]

      assert_raise ValidationError,
                   ~r/expected :scope to be a non-empty string or tuple, got: :an_atom/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       scope: :an_atom
                     )
                   end

      assert_raise ValidationError,
                   ~r/expected :scope to be a non-empty string or tuple, got: 1/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       scope: 1
                     )
                   end

      assert_raise ValidationError,
                   ~r/expected :scope to be a non-empty string or tuple, got: {}/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       scope: {}
                     )
                   end

      assert_raise ValidationError,
                   ~r/expected :scope to be a non-empty string or tuple, got: {}/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       scope: {}
                     )
                   end

      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} =
               prepare_for_start_module_opts(
                 subscription: "projects/foo/subscriptions/bar",
                 scope: {"mail@example.com", "https://example.com"}
               )

      assert {_, _, [{"mail@example.com", "https://example.com"}]} =
               producer_opts[:token_generator]
    end

    test ":token_generator defaults to using Goth with default scope" do
      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} = prepare_for_start_module_opts(subscription: "projects/foo/subscriptions/bar")

      assert producer_opts[:token_generator] ==
               {BroadwayCloudPubSub.Options, :generate_goth_token,
                ["https://www.googleapis.com/auth/pubsub"]}
    end

    test ":token_generator should be a tuple {Mod, Fun, Args}" do
      token_generator = {Token, :fetch, []}

      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} =
               prepare_for_start_module_opts(
                 subscription: "projects/foo/subscriptions/bar",
                 token_generator: token_generator
               )

      assert producer_opts[:token_generator] == token_generator

      assert_raise ValidationError,
                   ~r/expected :token_generator to be a tuple {Mod, Fun, Args}, got: {1, 1, 1}/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       token_generator: {1, 1, 1}
                     )
                   end

      assert_raise ValidationError,
                   ~r/expected :token_generator to be a tuple {Mod, Fun, Args}, got: SomeModule/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       token_generator: SomeModule
                     )
                   end
    end

    test ":receive_timeout is optional with default value :infinity" do
      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} = prepare_for_start_module_opts(subscription: "projects/foo/subscriptions/bar")

      assert producer_opts[:receive_timeout] == :infinity
    end

    test ":receive_timeout should be a positive integer or :infinity" do
      for value <- [0, -1, :an_atom, SomeModule] do
        assert_raise ValidationError,
                     ~r/expected :receive_timeout to be a positive integer or :infinity, got: #{inspect(value)}/,
                     fn ->
                       prepare_for_start_module_opts(
                         subscription: "projects/foo/subscriptions/bar",
                         receive_timeout: value
                       )
                     end
      end

      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} =
               prepare_for_start_module_opts(
                 subscription: "projects/foo/subscriptions/bar",
                 receive_timeout: 15_000
               )

      assert producer_opts[:receive_timeout] == 15_000
    end

    test ":on_success defaults to :ack" do
      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} = prepare_for_start_module_opts(subscription: "projects/foo/subscriptions/bar")

      assert producer_opts[:on_success] == :ack
    end

    test ":on_failure defaults to :noop" do
      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} = prepare_for_start_module_opts(subscription: "projects/foo/subscriptions/bar")

      assert producer_opts[:on_failure] == :noop
    end

    test ":on_success should be a valid action" do
      for action <- [:ack, :noop, {:nack, 0}, {:nack, 100}, {:nack, 600}] do
        assert {_,
                [
                  producer: [
                    module: {BroadwayCloudPubSub.Producer, producer_opts},
                    concurrency: 1
                  ]
                ]} =
                 prepare_for_start_module_opts(
                   subscription: "projects/foo/subscriptions/bar",
                   on_success: action
                 )

        assert producer_opts[:on_success] == action
      end

      assert_raise ValidationError,
                   ~r/expected :on_success to be one of :ack, :noop, :nack, or {:nack, integer} where integer is between 0 and 600, got: :foo/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       on_success: :foo
                     )
                   end

      assert_raise ValidationError,
                   ~r/expected :on_success to be one of :ack, :noop, :nack, or {:nack, integer} where integer is between 0 and 600, got: "foo"/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       on_success: "foo"
                     )
                   end

      assert_raise ValidationError,
                   ~r/expected :on_success to be one of :ack, :noop, :nack, or {:nack, integer} where integer is between 0 and 600, got: 1/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       on_success: 1
                     )
                   end

      assert_raise ValidationError,
                   ~r/expected :on_success to be one of :ack, :noop, :nack, or {:nack, integer} where integer is between 0 and 600, got: SomeModule/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       on_success: SomeModule
                     )
                   end
    end

    test ":on_failure should be a valid action" do
      for action <- [:ack, :noop, {:nack, 0}, {:nack, 100}, {:nack, 600}] do
        assert {_,
                [
                  producer: [
                    module: {BroadwayCloudPubSub.Producer, producer_opts},
                    concurrency: 1
                  ]
                ]} =
                 prepare_for_start_module_opts(
                   subscription: "projects/foo/subscriptions/bar",
                   on_failure: action
                 )

        assert producer_opts[:on_failure] == action
      end

      assert_raise ValidationError,
                   ~r/expected :on_failure to be one of :ack, :noop, :nack, or {:nack, integer} where integer is between 0 and 600, got: :foo/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       on_failure: :foo
                     )
                   end

      assert_raise ValidationError,
                   ~r/expected :on_failure to be one of :ack, :noop, :nack, or {:nack, integer} where integer is between 0 and 600, got: "foo"/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       on_failure: "foo"
                     )
                   end

      assert_raise ValidationError,
                   ~r/expected :on_failure to be one of :ack, :noop, :nack, or {:nack, integer} where integer is between 0 and 600, got: 1/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       on_failure: 1
                     )
                   end

      assert_raise ValidationError,
                   ~r/expected :on_failure to be one of :ack, :noop, :nack, or {:nack, integer} where integer is between 0 and 600, got: SomeModule/,
                   fn ->
                     prepare_for_start_module_opts(
                       subscription: "projects/foo/subscriptions/bar",
                       on_failure: SomeModule
                     )
                   end
    end

    test "custom action :nack casts to {:nack, 0}" do
      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} =
               prepare_for_start_module_opts(
                 on_failure: :nack,
                 on_success: :nack,
                 subscription: "projects/foo/subscriptions/bar"
               )

      assert producer_opts[:on_success] == {:nack, 0}
      assert producer_opts[:on_failure] == {:nack, 0}
    end

    test ":pool_size is optional with default value twice the producer concurrency" do
      assert {_,
              [
                producer: [
                  module: {BroadwayCloudPubSub.Producer, producer_opts},
                  concurrency: 1
                ]
              ]} = prepare_for_start_module_opts(subscription: "projects/foo/subscriptions/bar")

      assert producer_opts[:pool_size] == 2
    end

    test "with :client PullClient returns a child_spec for starting a Finch pool" do
      assert {
               [
                 {Finch,
                  name: BroadwayCloudPubSub.ProducerTest.Forwarder.PullClient,
                  pools: %{default: [size: 5]}}
               ],
               [
                 producer: [
                   module: {BroadwayCloudPubSub.Producer, _producer_opts},
                   concurrency: 1
                 ]
               ]
             } =
               prepare_for_start_module_opts(
                 subscription: "projects/foo/subscriptions/bar",
                 pool_size: 5
               )
    end
  end

  test "receive messages when the queue has less than the demand" do
    {:ok, message_server} = MessageServer.start_link()
    {:ok, pid} = start_broadway(message_server)

    MessageServer.push_messages(message_server, 1..5)

    assert_receive {:messages_received, 5}

    for msg <- 1..5 do
      assert_receive {:message_handled, ^msg}
    end

    stop_broadway(pid)
  end

  test "keep receiving messages when the queue has more than the demand" do
    {:ok, message_server} = MessageServer.start_link()
    MessageServer.push_messages(message_server, 1..20)
    {:ok, pid} = start_broadway(message_server)

    assert_receive {:messages_received, 10}

    for msg <- 1..10 do
      assert_receive {:message_handled, ^msg}
    end

    assert_receive {:messages_received, 5}

    for msg <- 11..15 do
      assert_receive {:message_handled, ^msg}
    end

    assert_receive {:messages_received, 5}

    for msg <- 16..20 do
      assert_receive {:message_handled, ^msg}
    end

    assert_receive {:messages_received, 0}

    stop_broadway(pid)
  end

  test "keep trying to receive new messages when the queue is empty" do
    {:ok, message_server} = MessageServer.start_link()
    {:ok, pid} = start_broadway(message_server)

    MessageServer.push_messages(message_server, [13])
    assert_receive {:messages_received, 1}
    assert_receive {:message_handled, 13}

    assert_receive {:messages_received, 0}
    refute_receive {:message_handled, _}

    MessageServer.push_messages(message_server, [14, 15])
    assert_receive {:messages_received, 2}
    assert_receive {:message_handled, 14}
    assert_receive {:message_handled, 15}

    stop_broadway(pid)
  end

  test "stop trying to receive new messages after start draining" do
    {:ok, message_server} = MessageServer.start_link()
    broadway_name = new_unique_name()
    {:ok, pid} = start_broadway(broadway_name, message_server)

    [producer] = Broadway.producer_names(broadway_name)

    assert_receive {:messages_received, 0}

    :sys.suspend(producer)
    flush_messages_received()
    task = Task.async(fn -> Broadway.Topology.ProducerStage.drain(producer) end)
    :sys.resume(producer)
    Task.await(task)

    refute_receive {:messages_received, _}, 10

    stop_broadway(pid)
  end

  test "delete acknowledged messages" do
    {:ok, message_server} = MessageServer.start_link()
    {:ok, pid} = start_broadway(message_server)

    MessageServer.push_messages(message_server, 1..20)

    assert_receive {:messages_deleted, 10}
    assert_receive {:messages_deleted, 10}

    stop_broadway(pid)
  end

  describe "calling Client.prepare_to_connect/2" do
    test "with default options, pool_size is twice the producers" do
      {:ok, message_server} = MessageServer.start_link()
      broadway_name = new_unique_name()
      {:ok, pid} = start_broadway(broadway_name, message_server, FakePoolClient)

      assert_receive {:pool_started, pool}, 500
      assert_receive {:connection_pool_set, ^pool}, 500
      assert FakePool.pool_size(pool) == 2

      stop_broadway(pid)
    end

    test "with user-defined pool_size" do
      {:ok, message_server} = MessageServer.start_link()
      broadway_name = new_unique_name()
      {:ok, pid} = start_broadway(broadway_name, message_server, FakePoolClient, pool_size: 20)

      assert_receive {:pool_started, pool}, 500
      assert_receive {:connection_pool_set, ^pool}, 500
      assert FakePool.pool_size(pool) == 20

      stop_broadway(pid)
    end
  end

  defp start_broadway(
         broadway_name \\ new_unique_name(),
         message_server,
         client \\ FakeClient,
         opts \\ []
       ) do
    Broadway.start_link(
      Forwarder,
      build_broadway_opts(broadway_name, opts,
        client: client,
        subscription: "projects/my-project/subscriptions/my-subscription",
        receive_interval: 0,
        test_pid: self(),
        message_server: message_server
      )
    )
  end

  defp build_broadway_opts(broadway_name, opts, producer_opts) do
    [
      name: broadway_name,
      context: %{test_pid: self()},
      producer: [
        module: {BroadwayCloudPubSub.Producer, Keyword.merge(producer_opts, opts)},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 1]
      ],
      batchers: [
        default: [
          batch_size: 10,
          batch_timeout: 50,
          concurrency: 1
        ]
      ]
    ]
  end

  defp new_unique_name() do
    :"Broadway#{System.unique_integer([:positive, :monotonic])}"
  end

  defp stop_broadway(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :normal)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  defp flush_messages_received() do
    receive do
      {:messages_received, 0} -> flush_messages_received()
    after
      0 -> :ok
    end
  end
end
