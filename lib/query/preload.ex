defmodule QueryBuilder.Query.Preload do
  @moduledoc false

  require Ecto.Query

  def preload(%QueryBuilder.Query{ecto_query: query, token: token}, assoc_fields) do
    %QueryBuilder.Query{
      ecto_query: query,
      token: Map.update(token, :preload, assoc_fields, &(&1 ++ assoc_fields))
    }
  end

  def preload(query, assoc_fields) do
    %QueryBuilder.Query{
      ecto_query: query,
      token: %{list_assoc_data: [], preload: []}
    }
    |> preload(assoc_fields)
  end

  def do_preload(query, _token, []), do: query

  def do_preload(query, token, assoc_fields) do
    token = QueryBuilder.Token.token(query, token, assoc_fields)

    # Join one-to-one associations as it is more advantageous to include those into
    # the result set rather than emitting a new DB query.
    %QueryBuilder.Query{ecto_query: query, token: token} =
      QueryBuilder.JoinMaker.make_joins(query, token, mode: :if_preferable)

    flattened_assoc_data = flatten_assoc_data(token)

    # Firstly, give `Ecto.Query.preload/3` the list of associations that have been
    # joined, such as:
    # `Ecto.Query.preload.(query, [articles: a, user: u, role: r], [articles: {a, [user: {u, [role: r]}]}])`
    query =
      flattened_assoc_data
      # Filter only the associations that have been joined
      |> Enum.map(fn assoc_data_list ->
        Enum.flat_map(assoc_data_list, fn
          %{has_joined: false} -> []
          assoc_data -> [{assoc_data.assoc_binding, assoc_data.assoc_field}]
        end)
      end)
      # Get rid of the associations' lists that are redundant;
      # for example for the 4 lists below:
      # `[{:binding1, :field1}]`
      # `[{:binding1, :field1}, {:binding2, :field2}]`
      # `[{:binding1, :field1}, {:binding2, :field2}]`
      # `[{:binding1, :field1}, {:binding2, :field2}, {:binding3, :field3}]`
      # only the last list should be preserved.
      |> Enum.uniq()
      |> (fn lists ->
            Enum.filter(
              lists,
              &(!Enum.any?(lists -- [&1], fn list ->
                  Keyword.equal?(&1, Enum.slice(list, 0, length(&1)))
                end))
            )
          end).()
      |> Enum.reduce(query, fn list, query ->
        do_preload_with_bindings(query, list)
      end)

    # Secondly, give `Ecto.Query.preload/3` the list of associations that have not
    # been joined, such as:
    # `Ecto.Query.preload(query, [articles: [comments: :comment_likes]])`
    query =
      flattened_assoc_data
      |> Enum.map(fn assoc_data_list ->
        Enum.reverse(assoc_data_list)
        |> Enum.drop_while(& &1.has_joined)
        |> Enum.map(& &1.assoc_field)
        |> Enum.reverse()
      end)
      |> Enum.reject(&Enum.empty?(&1))
      |> Enum.map(&convert_list_to_nested_keyword_list(&1))
      |> Enum.reduce(query, fn list, query ->
        atom_or_tuple = hd(list)
        Ecto.Query.preload(query, ^atom_or_tuple)
      end)

    query
  end

  defp flatten_assoc_data(%{list_assoc_data: list_assoc_data}) do
    Enum.flat_map(list_assoc_data, &do_flatten_assoc_data/1)
  end

  defp do_flatten_assoc_data(%{nested_assocs: []} = assoc_data) do
    [[Map.delete(assoc_data, :nested_assocs)]]
  end

  defp do_flatten_assoc_data(%{nested_assocs: nested_assocs} = assoc_data) do
    for nested_assoc_data <- nested_assocs,
        rest <- do_flatten_assoc_data(nested_assoc_data) do
      [Map.delete(assoc_data, :nested_assocs) | rest]
    end
  end

  defp convert_list_to_nested_keyword_list(list) do
    do_convert_list_to_nested_keyword_list(list)
    |> List.wrap()
  end

  defp do_convert_list_to_nested_keyword_list([]), do: []
  defp do_convert_list_to_nested_keyword_list([e]), do: e

  defp do_convert_list_to_nested_keyword_list([head | [penultimate, last]]),
    do: [{head, [{penultimate, last}]}]

  defp do_convert_list_to_nested_keyword_list([head | tail]),
    do: [{head, do_convert_list_to_nested_keyword_list(tail)}]

  defp do_preload_with_bindings(query, []), do: query

  # 🤢
  defp do_preload_with_bindings(query, [{assoc_binding, assoc_field}]) do
    Ecto.Query.preload(query, [{^assoc_binding, x}], [
      {^assoc_field, x}
    ])
  end

  # 🤢🤢
  defp do_preload_with_bindings(query, [
         {assoc_binding1, assoc_field1},
         {assoc_binding2, assoc_field2}
       ]) do
    Ecto.Query.preload(query, [{^assoc_binding1, x}, {^assoc_binding2, y}], [
      {^assoc_field1, {x, [{^assoc_field2, y}]}}
    ])
  end

  # 🤢🤢🤮
  defp do_preload_with_bindings(query, [
         {assoc_binding1, assoc_field1},
         {assoc_binding2, assoc_field2},
         {assoc_binding3, assoc_field3}
       ]) do
    Ecto.Query.preload(
      query,
      [{^assoc_binding1, x}, {^assoc_binding2, y}, {^assoc_binding3, z}],
      [
        {^assoc_field1, {x, [{^assoc_field2, {y, [{^assoc_field3, z}]}}]}}
      ]
    )
  end

  # 🤢🤢🤮🤮
  defp do_preload_with_bindings(query, [
         {assoc_binding1, assoc_field1},
         {assoc_binding2, assoc_field2},
         {assoc_binding3, assoc_field3},
         {assoc_binding4, assoc_field4}
       ]) do
    Ecto.Query.preload(
      query,
      [{^assoc_binding1, x}, {^assoc_binding2, y}, {^assoc_binding3, z}, {^assoc_binding4, a}],
      [
        {^assoc_field1, {x, [{^assoc_field2, {y, [{^assoc_field3, {z, [{^assoc_field4, a}]}}]}}]}}
      ]
    )
  end

  # 🤢🤢🤮🤮🤮
  defp do_preload_with_bindings(query, [
         {assoc_binding1, assoc_field1},
         {assoc_binding2, assoc_field2},
         {assoc_binding3, assoc_field3},
         {assoc_binding4, assoc_field4},
         {assoc_binding5, assoc_field5}
       ]) do
    Ecto.Query.preload(
      query,
      [
        {^assoc_binding1, x},
        {^assoc_binding2, y},
        {^assoc_binding3, z},
        {^assoc_binding4, a},
        {^assoc_binding5, b}
      ],
      [
        {^assoc_field1,
         {x,
          [
            {^assoc_field2,
             {y, [{^assoc_field3, {z, [{^assoc_field4, {a, [{^assoc_field5, b}]}}]}}]}}
          ]}}
      ]
    )
  end

  # 🤢🤢🤮🤮🤮🤮
  defp do_preload_with_bindings(query, [
         {assoc_binding1, assoc_field1},
         {assoc_binding2, assoc_field2},
         {assoc_binding3, assoc_field3},
         {assoc_binding4, assoc_field4},
         {assoc_binding5, assoc_field5},
         {assoc_binding6, assoc_field6}
       ]) do
    Ecto.Query.preload(
      query,
      [
        {^assoc_binding1, x},
        {^assoc_binding2, y},
        {^assoc_binding3, z},
        {^assoc_binding4, a},
        {^assoc_binding5, b},
        {^assoc_binding6, c}
      ],
      [
        {^assoc_field1,
         {x,
          [
            {^assoc_field2,
             {y,
              [
                {^assoc_field3,
                 {z, [{^assoc_field4, {a, [{^assoc_field5, {b, [{^assoc_field6, c}]}}]}}]}}
              ]}}
          ]}}
      ]
    )
  end
end
