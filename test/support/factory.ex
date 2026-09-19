defmodule RetrofitControl.TestFactory do
  @moduledoc """
  测试支撑：为每个用例启动相互隔离的 Journal/Engine/Dispatcher，
  进程退出自动清理。默认不自动轮询投递，需要采购回执时显式 `flush/1`。
  """

  import ExUnit.Callbacks, only: [start_supervised: 1, stop_supervised!: 1]

  alias RetrofitControl.{Engine, Journal, Procurement}

  def unique_dir do
    Path.join(System.tmp_dir!(), "rc-test-#{:erlang.unique_integer([:positive])}")
  end

  def start_context(_meta \\ %{}) do
    dir = unique_dir()
    File.rm_rf!(dir)

    ref = :erlang.unique_integer([:positive])
    name = Module.concat(EngineTest, "E#{ref}")
    jname = Module.concat(JournalTest, "J#{ref}")
    dname = Module.concat(DispatcherTest, "D#{ref}")
    cname = Module.concat(ClockTest, "C#{ref}")

    {:ok, _} = RetrofitControl.Util.start_clock(cname)

    {:ok, _} =
      start_supervised(%{
        id: {:journal, ref},
        start: {Journal, :start_link, [[dir: dir, name: jname]]}
      })

    {:ok, engine} =
      start_supervised(%{
        id: {:engine, ref},
        start: {Engine, :start_link, [[dir: dir, journal: jname, clock: cname, name: name]]}
      })

    # 等待引擎完成事件重放
    _ = Engine.state(engine)

    # 采购模拟系统为测试级单例（在 test_helper 启动），每个用例前清空去重表/故障模式
    Procurement.MockServer.reset()
    Procurement.MockClient.set_mode("ok")

    {:ok, dispatcher} =
      start_supervised(%{
        id: {:dispatcher, ref},
        start:
          {Procurement.Dispatcher, :start_link,
           [[client: Procurement.MockClient, engine: engine, auto: false, name: dname]]}
      })

    %{
      dir: dir,
      engine: engine,
      journal: jname,
      clock: cname,
      dispatcher: dispatcher,
      client: Procurement.MockClient,
      sup_ids: [{:journal, ref}, {:engine, ref}, {:dispatcher, ref}]
    }
  end

  def set_time(ctx, %Date{} = date) do
    RetrofitControl.Util.set_clock(
      fn -> DateTime.new!(date, ~T[10:00:00.000000]) end,
      ctx.clock
    )
  end

  def reset_time(ctx) do
    RetrofitControl.Util.set_clock(nil, ctx.clock)
  end

  def flush(ctx) do
    Procurement.Dispatcher.flush(ctx.dispatcher)
  end

  def set_mode(_ctx, mode) do
    Procurement.MockClient.set_mode(mode)
  end
end
