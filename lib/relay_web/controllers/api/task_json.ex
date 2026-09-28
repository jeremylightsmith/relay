defmodule RelayWeb.Api.TaskJSON do
  @moduledoc """
  JSON for a card's tasks (RE355). `task_summary/1` is the ONE definition of the summary shape —
  deliberately without `body`, so a list shows THAT other tasks exist, not their content —
  and `task/1` is that shape plus `body`. `CardJSON.show/1` renders its `sub_tasks` with `task/1`.
  """

  def index(%{tasks: tasks}), do: %{data: Enum.map(tasks, &task_summary/1)}

  def show(%{task: task}), do: %{data: task(task)}

  def summary(%{task: task}), do: %{data: task_summary(task)}

  def task_summary(%Schemas.SubTask{} = st), do: %{id: st.id, title: st.title, done: st.done, position: st.position}

  def task(%Schemas.SubTask{} = st), do: Map.put(task_summary(st), :body, st.body)
end
