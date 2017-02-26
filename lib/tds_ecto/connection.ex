if Code.ensure_loaded?(Tds) do
  defmodule Tds.Ecto.Connection do
    @moduledoc false
    require Logger
    @default_port System.get_env("MSSQLPORT") || 1433

    @behaviour Ecto.Adapters.SQL.Connection
    # @behaviour Ecto.Adapters.SQL.Query
    
    def connect(opts) do
      opts = opts
        |> Keyword.put_new(:port, @default_port)
      Tds.Protocol.connect(opts)
    end

    def child_spec(opts) do
      Tds.child_spec(opts)
    end

    alias Tds.Query
    alias Tds.Parameter

    def prepare_execute(pid, _name, statement, params, opts \\ []) do
      query = %Query{statement: statement}
      {params, _} = Enum.map_reduce params, 1, fn(param, acc) ->
        {value, type} = prepare_param(param)
        {%Tds.Parameter{name: "@#{acc}", value: value, type: type}, acc + 1}
      end
      opts = Keyword.put(opts, :parameters, params)
      DBConnection.prepare_execute(pid, query, params, opts)
    end

    def execute(pid, statement, params, opts) when is_binary(statement) or is_list(statement) do
      query = %Query{statement: statement}
      {params, _} = Enum.map_reduce params, 1, fn(param, acc) ->
        {value, type} = prepare_param(param)
        {%Tds.Parameter{name: "@#{acc}", value: value, type: type}, acc + 1}
      end
      opts = Keyword.put(opts, :parameters, params)

			case DBConnection.prepare_execute(pid, query, params, opts) do
        {:ok, _, %Tds.Result{columns: nil, command: nil, num_rows: 1, rows: []}} ->
          {:ok,  %Tds.Result{columns: nil, command: nil, num_rows: 1, rows: nil}}
        {:ok, _, query} -> {:ok, query}
        {:error, _} = err -> err
      end
    end
    def execute(pid, %{} = query, params, opts) do
      opts = Keyword.put_new(opts, :parameters, params)
      {params, _} = Enum.map_reduce params, 1, fn(param, acc) ->
        {value, type} = prepare_param(param)
        {%Tds.Parameter{name: "@#{acc}", value: value, type: type}, acc + 1}
      end
      opts = Keyword.put(opts, :parameters, params)
			case DBConnection.prepare_execute(pid, query, params, opts) do
        {:ok, _, query} -> {:ok, query}
        {:error, _} = err -> err
      end
    end

    def query(conn, sql, params, opts) do
      {params, _} = Enum.map_reduce params, 1, fn(param, acc) ->
        {value, type} = prepare_param(param)
        {%Tds.Parameter{name: "@#{acc}", value: value, type: type}, acc + 1}
      end
      case Tds.query(conn, sql, params, opts) do
        {:ok, %Tds.Result{} = result} ->
          {:ok, Map.from_struct(result)}
        {:error, %Tds.Error{}} = err  -> err
      end
    end

    
    defp prepare_param(%Ecto.Query.Tagged{value: true, type: :boolean}),                                 do: {1, :boolean}
    defp prepare_param(%Ecto.Query.Tagged{value: false, type: :boolean}),                                do: {0, :boolean}
    defp prepare_param(%Ecto.Query.Tagged{value: value, type: :binary}) when value == "",                do: {value, :string}
    defp prepare_param(%Ecto.Query.Tagged{value: value, type: :binary}),                                 do: {value, :binary}
    defp prepare_param(%Ecto.Query.Tagged{value: {{y,m,d},{hh,mm,ss,us}}, type: :datetime}) when us > 0, do: {{{y,m,d},{hh,mm,ss, us}}, :datetime2}
    defp prepare_param(%Ecto.Query.Tagged{value: {{y,m,d},{hh,mm,ss,us}}, type: :datetime}),             do: {{{y,m,d},{hh,mm,ss}}, :datetime}
    defp prepare_param(%Ecto.Query.Tagged{value: nil, type: type}) when type in [:binary_id, :uuid],     do: {nil, :binary}
    defp prepare_param(%Ecto.Query.Tagged{value: value, type: type}) when type in [:binary_id, :uuid]    do
      if String.length(value) > 16 do
        {:ok, value} = Ecto.UUID.cast(value)
        {value, :string}
      else
        {uuid(value), :binary}
      end
    end
    defp prepare_param(%Ecto.Query.Tagged{value: value, type: type}) when type in [:binary_id, :uuid],     do: {value, type}
    defp prepare_param(%{__struct__: _} = value),                                                          do: {value, nil}
    defp prepare_param(%{} = value),                                                                       do: {json_library.encode!(value), :string}
    defp prepare_param(value),                                                                             do: param(value)

    defp param(value) when is_binary(value) do
      case :unicode.characters_to_binary(value, :utf8, {:utf16, :little}) do
        {:error, _, _} -> {value, :binary}
        val -> {val, nil}
      end
    end

    defp param({_,_,_} = value), do: {value, :date}
    defp param(value) when value == true, do: {1, :boolean}
    defp param(value) when value == false, do: {0, :boolean}
    defp param(value), do: {value, nil}

    defp json_library do
      Application.get_env(:ecto, :json_library)
    end

    def to_constraints(%Tds.Error{mssql: %{number: 2601, msg_text: message}}) do
      # Might non match on non-English error messages
      case Regex.run(~r/('.*?'|".*?").*('.*?'|".*?")/, message, capture: :all_but_first) do
        [_, index] -> [unique: strip_quotes(index)]
        _ -> [unique: "<unknown_unique_index>"]
      end
    end
    def to_constraints(%Tds.Error{mssql: %{number: 2627, msg_text: message}}) do
      # Might non match on non-English error messages
      case Regex.run(~r/('.*?'|".*?")/, message, capture: :all_but_first) do
        [index] -> [unique: strip_quotes(index)]
        _ -> [unique: "<unknown_unique_constraint>"]
      end
    end
    def to_constraints(%Tds.Error{mssql: %{number: 547, msg_text: message}}) do
      # Might non match on non-English error messages
      case Regex.run(~r/('.*?'|".*?")/, message, capture: :all_but_first) do
        [foreign_key] -> [unique: strip_quotes(foreign_key)]
        _ -> [foreign_key: "<unknown_foreign_key>"]
      end
    end
    def to_constraints(%Tds.Error{}),
      do: []

    defp strip_quotes(quoted) do
      size = byte_size(quoted) - 2
      <<_, unquoted::binary-size(size), _>> = quoted
      unquoted
    end

    ## Transaction

    def begin_transaction do
      "BEGIN TRANSACTION"
    end

    def rollback do
      "ROLLBACK TRANSACTION"
    end

    def commit do
      "COMMIT TRANSACTION"
    end

    def savepoint(savepoint) do
      "SAVE TRANSACTION " <> savepoint
    end

    def rollback_to_savepoint(savepoint) do
      "ROLLBACK TRANSACTION " <> savepoint <> ";" <> savepoint(savepoint)

    end

    ## Query

    alias Ecto.Query
    alias Ecto.Query.SelectExpr
    alias Ecto.Query.QueryExpr
    alias Ecto.Query.JoinExpr

    def all(query) do
      sources = create_names(query)

      from     = from(sources, query.lock)
      select   = select(query, sources)
      join     = join(query, sources)
      where    = where(query, sources)
      group_by = group_by(query, sources)
      having   = having(query, sources)
      order_by = order_by(query, sources)

      offset   = offset(query, sources)

      if (query.offset != nil and query.order_bys == []), do: error!(query, "ORDER BY is mandatory to use OFFSET")
      assemble([select, from, join, where, group_by, having, order_by, offset])
    end

    def update_all(query) do
      sources = create_names(query)
      {table, name, _model} = elem(sources, 0)

      update = "UPDATE #{name}"
      fields = update_fields(query, sources)
      from   = "FROM #{table} AS #{name}"
      join   = join(query, sources)
      where  = where(query, sources)

      assemble([update, "SET", fields, from, join, where])
    end

    def delete_all(query) do
      sources = create_names(query)
      {table, name, _model} = elem(sources, 0)

      delete = "DELETE #{name}"
      from   = "FROM #{table} AS #{name}"
      join   = join(query, sources)
      where  = where(query, sources)

      assemble([delete, from, join, where])
    end
    
    # def insert(prefix, table, fields, returning) do
    #   values =
    #     if fields == [] do
    #       returning(returning, "INSERTED") <>
    #       "DEFAULT VALUES"
    #     else
    #       "(" <> Enum.map_join(fields, ", ", &quote_name/1) <> ")" <>
    #       " " <> returning(returning, "INSERTED") <>
    #       "VALUES (" <> Enum.map_join(1..length(fields), ", ", &"@#{&1}") <> ")"
    #     end
    #   "INSERT INTO #{quote_table(prefix, table)} " <> values
    # end
    def insert(prefix, table, header, rows, on_conflict, returning) do
      [] = on_conflict(on_conflict, header)
      values =
        if header == [] do
          returning(returning, "INSERTED") <>
            "DEFAULT VALUES"
        else
          "(" <> Enum.map_join(header, ", ", &quote_name/1) <> ")" <>
            " " <> returning(returning, "INSERTED") <>
            "VALUES " <> insert_all(rows, 1, "")
        end
      "INSERT INTO #{quote_table(prefix, table)} " <> values
    end

    defp on_conflict({_, _, [_ | _]}, _header) do
      error!(nil, "The :conflict_target option is not supported in insert/insert_all by TDS")
    end
    defp on_conflict({:raise, _, []}, _header) do
      []
    end
    defp on_conflict({:nothing, _, []}, [field | _]) do
      error!(nil, "The :nothing option is not supported in insert/insert_all by TDS")
    end
    defp on_conflict({:replace_all, _, []}, header) do
      error!(nil, "The :replace_all option is not supported in insert/insert_all by TDS")
    end
    defp on_conflict({query, _, []}, _header) do
      error!(nil, "The query as option for on_conflict is not supported in insert/insert_all by TDS yet.")
    end

		defp insert_all([row|rows], counter, acc) do
      {counter, row} = insert_each(row, counter, "")
      insert_all(rows, counter, acc <> ",(" <> row <> ")")
    end
    defp insert_all([], _counter, "," <> acc) do
      acc
    end

    defp insert_each([nil|t], counter, acc),
      do: insert_each(t, counter, acc <> ",DEFAULT")
    defp insert_each([_|t], counter, acc),
      do: insert_each(t, counter + 1, acc <> ", @" <> Integer.to_string(counter))
    defp insert_each([], counter, "," <> acc),
      do: {counter, acc}


    def update(prefix, table, fields, filters, returning) do
      {fields, count} = Enum.map_reduce fields, 1, fn field, acc ->
        {"#{quote_name(field)} = @#{acc}", acc + 1}
      end

      {filters, _count} = Enum.map_reduce filters, count, fn field, acc ->
        {"#{quote_name(field)} = @#{acc}", acc + 1}
      end
      "UPDATE #{quote_table(prefix, table)} SET " <> Enum.join(fields, ", ") <>
      " " <> returning(returning, "INSERTED") <>
        "WHERE " <> Enum.join(filters, " AND ")
    end

    def delete(prefix, table, filters, returning) do
      {filters, _} = Enum.map_reduce filters, 1, fn field, acc ->
        {"#{quote_name(field)} = @#{acc}", acc + 1}
      end

      "DELETE FROM #{quote_table(prefix, table)}" <>
      " " <> returning(returning,"DELETED") <> "WHERE " <> Enum.join(filters, " AND ")
    end

    ## Query generation

    binary_ops =
      [==: "=", !=: "!=", <=: "<=", >=: ">=", <:  "<", >:  ">",
       and: "AND", or: "OR", ilike: "LIKE", like: "LIKE"]

    @binary_ops Keyword.keys(binary_ops)

    Enum.map(binary_ops, fn {op, str} ->
      defp handle_call(unquote(op), 2), do: {:binary_op, unquote(str)}
    end)

    defp handle_call(fun, _arity), do: {:fun, Atom.to_string(fun)}

    defp select(%Query{select: %SelectExpr{fields: fields}, distinct: []} = query, sources) do
      "SELECT " <> limit(query, sources) <> select(fields, sources, query)
    end

    defp select(%Query{select: %SelectExpr{fields: fields}} = query, sources) do
      "SELECT " <>
        distinct(query, sources) <>
        limit(query, sources) <>
        select(fields, sources, query)
    end

    defp select([], sources, %Query{select: %SelectExpr{expr: val}} = query) do
      expr(val, sources, query)
    end
    defp select(fields, sources, query) do
      Enum.map_join(fields, ", ", &expr(&1, sources, query))
    end

    defp distinct(%Query{distinct: nil}, _sources), do: ""
    defp distinct(%Query{distinct: %QueryExpr{expr: true}}, _sources),  do: "DISTINCT "
    defp distinct(%Query{distinct: %QueryExpr{expr: false}}, _sources), do: ""
    defp distinct(%Query{distinct: %QueryExpr{expr: _exprs}} = query, _sources) do
      error!(query, "TDS does not allow expressions in distinct")
    end

    defp from(sources, lock) do
      {table, name, _model} = elem(sources, 0)
      "FROM #{table} AS #{name}" <> lock(lock) |> String.strip
    end

    defp update_fields(%Query{updates: updates} = query, sources) do
      for(%{expr: expr} <- updates,
          {op, kw} <- expr,
          {key, value} <- kw,
          do: update_op(op, key, value, sources, query)) |> Enum.join(", ")
    end

    defp update_op(:set, key, value, sources, query) do
      {_table, name, _model} = elem(sources, 0)
      name <> "." <> quote_name(key) <> " = " <> expr(value, sources, query)
    end

    defp update_op(:inc, key, value, sources, query) do
      {_table, name, _model} = elem(sources, 0)
      quoted = quote_name(key)
      name <> "." <> quoted <> " = " <> name <> "." <> quoted <> " + " <> expr(value, sources, query)
    end

    defp update_op(command, _key, _value, _sources, query) do
      error!(query, "Unknown update operation #{inspect command} for TDS")
    end

    defp join(%Query{joins: []}, _sources), do: nil
    defp join(%Query{joins: joins, lock: lock} = query, sources) do
      Enum.map_join(joins, " ", fn
        %JoinExpr{on: %QueryExpr{expr: expr}, qual: qual, ix: ix, source: source} ->
          {join, name, _model} = elem(sources, ix)
          qual = join_qual(qual)
          join = join || "(" <> expr(source, sources, query) <> ")"
          "#{qual} JOIN " <> join <> " AS #{name} " <> lock(lock) <> "ON " <> expr(expr, sources, query)
      end)
    end

    defp join_qual(:inner), do: "INNER"
    defp join_qual(:left),  do: "LEFT OUTER"
    defp join_qual(:right), do: "RIGHT OUTER"
    defp join_qual(:full),  do: "FULL OUTER"

    defp where(%Query{wheres: wheres} = query, sources) do
      boolean("WHERE", wheres, sources, query)
    end

    defp having(%Query{havings: havings} = query, sources) do
      boolean("HAVING", havings, sources, query)
    end

    defp group_by(%Query{group_bys: group_bys} = query, sources) do
      exprs =
        Enum.map_join(group_bys, ", ", fn
          %QueryExpr{expr: expr} ->
            Enum.map_join(expr, ", ", &expr(&1, sources, query))
        end)

      case exprs do
        "" -> nil
        _  -> "GROUP BY " <> exprs
      end
    end

    defp order_by(%Query{order_bys: order_bys} = query, sources) do
      exprs =
        Enum.map_join(order_bys, ", ", fn
          %QueryExpr{expr: expr} ->
            Enum.map_join(expr, ", ", &order_by_expr(&1, sources, query))
        end)

      case exprs do
        "" -> nil
        _  -> "ORDER BY " <> exprs
      end
    end

    defp order_by_expr({dir, expr}, sources, query) do
      str = expr(expr, sources, query)
      case dir do
        :asc  -> str
        :desc -> str <> " DESC"
      end
    end

    defp limit(%Query{limit: nil}, _sources), do: ""
    defp limit(%Query{limit: %QueryExpr{expr: expr}} = query, sources) do
      case Map.get(query, :offset) do
        nil -> "TOP(" <> expr(expr, sources, query) <> ") "
        _ -> ""
      end

    end

    defp offset(%Query{offset: nil}, _sources), do: nil
    defp offset(%Query{offset: %QueryExpr{expr: offset_expr}, limit: %QueryExpr{expr: limit_expr}} = query, sources) do
      "OFFSET " <> expr(offset_expr, sources, query) <> " ROW " <>
      "FETCH NEXT " <> expr(limit_expr, sources, query) <> " ROWS ONLY"
    end
    defp offset(%Query{offset: _} = query, _sources) do
      error!(query, "You must provide a limit while using an offset")
    end

    defp lock(nil), do: ""
    defp lock(lock_clause), do: " #{lock_clause} "

    defp boolean(_name, [], _sources, _query), do: nil
    defp boolean(name, query_exprs, sources, query) do
      name <> " " <>
        Enum.map_join(query_exprs, " AND ", fn
          %QueryExpr{expr: expr} ->
            case expr do
              true -> "(1 = 1)"
              false -> "(0 = 1)"
              _ -> "(" <> expr(expr, sources, query) <> ")"
            end
        end)
    end

    defp expr({:^, [], [ix]}, _sources, _query) do
      "@#{ix+1}"
    end

    defp expr({{:., _, [{:&, _, [idx]}, field]}, _, []}, sources, _query) when is_atom(field) do
      {_, name, _} = elem(sources, idx)
      "#{name}.#{quote_name(field)}"
    end

    defp expr({:&, _, [idx, fields, _counter]}, sources, query) do
      {table, name, schema} = elem(sources, idx)
      unless schema do
        error!(query, "TDS requires a model when using selector #{inspect name} but " <>
                             "only the table #{inspect table} was given. Please specify a schema " <>
                             "or specify exactly which fields from #{inspect name} you desire")
      end

      Enum.map_join(fields, ", ", &"#{name}.#{quote_name(&1)}")
    end

    defp expr({:in, _, [_left, []]}, _sources, _query) do
      "0=1"
    end

    defp expr({:in, _, [left, right]}, sources, query) when is_list(right) do
      args = Enum.map_join right, ",", &expr(&1, sources, query)
      expr(left, sources, query) <> " IN (" <> args <> ")"
    end

    defp expr({:in, _, [left, {:^, _, [ix, length]}]}, sources, query) do
      args = Enum.map_join ix+1..ix+length, ",", &"@#{&1}"
      expr(left, sources, query) <> " IN (" <> args <> ")"
    end

    defp expr({:in, _, [left, right]}, sources, query) do
      expr(left, sources, query) <> " IN (" <> expr(right, sources, query) <> ")"
    end

    defp expr({:is_nil, _, [arg]}, sources, query) do
      "#{expr(arg, sources, query)} IS NULL"
    end

    defp expr({:not, _, [expr]}, sources, query) do
      "NOT (" <> expr(expr, sources, query) <> ")"
    end

    defp expr({:fragment, _, [kw]}, _sources, query) when is_list(kw) or tuple_size(kw) == 3 do
      error!(query, "TDS adapter does not support keyword or interpolated fragments")
    end

    defp expr({:fragment, _, parts}, sources, query) do
      Enum.map_join(parts, "", fn
        {:raw, part}  -> part
        {:expr, expr} -> expr(expr, sources, query)
      end)
    end

    defp expr({:datetime_add, _, [datetime, count, interval]}, sources, query) do
      "CAST(DATEADD(" <>
        interval <> ", " <> interval_count(count, sources, query) <> ", " <> expr(datetime, sources, query) <>
        ") AS datetime2)"
    end

    defp expr({:date_add, _, [date, count, interval]}, sources, query) do
      "CAST(DATEADD(" <>
        interval <> ", " <> interval_count(count, sources, query) <> ", CAST(" <> expr(date, sources, query) <> " AS datetime2)" <>
        ") AS date)"
    end

    defp expr({fun, _, args}, sources, query) when is_atom(fun) and is_list(args) do
      {modifier, args} =
      case args do
        [rest, :distinct] -> {"DISTINCT ", [rest]}
        _ -> {"", args}
      end

      case handle_call(fun, length(args)) do
        {:binary_op, op} ->
          [left, right] = args
          op_to_binary(left, sources, query) <>
          " #{op} "
          <> op_to_binary(right, sources, query)

        {:fun, fun} ->
          "#{fun}(" <> modifier <> Enum.map_join(args, ", ", &expr(&1, sources, query)) <> ")"
      end
    end

    defp expr(list, sources, query) when is_list(list) do
      Enum.map_join(list, ", ", &expr(&1, sources, query))
    end

    defp expr(string, _sources, _query) when is_binary(string) do
      hex = string
        |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
        |> Base.encode16(case: :lower)
      "CONVERT(nvarchar(max), 0x#{hex})"
    end

    defp expr(%Decimal{} = decimal, _sources, _query) do
      Decimal.to_string(decimal, :normal)
    end

    defp expr(%Ecto.Query.Tagged{value: binary, type: :binary}, _sources, _query) when is_binary(binary) do
      hex = Base.encode16(binary, case: :lower)
      "0x#{hex}"
    end

    defp expr(%Ecto.Query.Tagged{value: binary, type: :uuid}, _sources, _query) when is_binary(binary) do
      if String.contains?(binary, "-"), do: {:ok, binary} = Ecto.UUID.dump(binary)
      uuid(binary)
    end

    defp expr(%Ecto.Query.Tagged{value: other, type: type}, sources, query) do
      "CAST(#{expr(other, sources, query)} AS #{column_type(type, [])})"
    end

    defp expr(nil, _sources, _query),   do: "NULL"
    defp expr(true, _sources, _query),  do: "1"
    defp expr(false, _sources, _query), do: "0"

    defp expr(literal, _sources, _query) when is_binary(literal) do
      "'#{escape_string(literal)}'"
    end

    defp expr(literal, _sources, _query) when is_integer(literal) do
      String.Chars.Integer.to_string(literal)
    end

    defp expr(literal, _sources, _query) when is_float(literal) do
      String.Chars.Float.to_string(literal)
    end

    defp op_to_binary({op, _, [_, _]} = expr, sources, query) when op in @binary_ops do
      "(" <> expr(expr, sources, query) <> ")"
    end

    defp op_to_binary(expr, sources, query) do
      expr(expr, sources, query)
    end

    defp interval_count(count, _sources, _query) when is_integer(count) do
      String.Chars.Integer.to_string(count)
    end

    defp interval_count(count, _sources, _query) when is_float(count) do
      :erlang.float_to_binary(count, [:compact, decimals: 16])
    end

    defp interval_count(count, sources, query) do
      expr(count, sources, query)
    end

    defp returning([], _verb),
      do: ""
    defp returning(returning, verb) do
      "OUTPUT " <> Enum.map_join(returning, ", ", fn(arg) -> "#{verb}.#{quote_name(arg)}" end) <> " "
    end

    # Brute force find unique name
    # defp unique_name(names, name, counter) do
    #   counted_name = name <> Integer.to_string(counter)
    #   if Enum.any?(names, fn {_, n, _} -> n == counted_name end) do
    #     unique_name(names, name, counter + 1)
    #   else
    #     counted_name
    #   end
    # end

    defp create_names(%{prefix: prefix, sources: sources}) do
      create_names(prefix, sources, 0, tuple_size(sources)) |> List.to_tuple()
    end

    defp create_names(prefix, sources, pos, limit) when pos < limit do
      current =
        case elem(sources, pos) do
          {table, model} ->
            name = String.first(table) <> Integer.to_string(pos)
            {quote_table(prefix, table), name, model}
          {:fragment, _, _} ->
            {nil, "f" <> Integer.to_string(pos), nil}
        end
      [current|create_names(prefix, sources, pos + 1, limit)]
    end

    defp create_names(_prefix, _sources, pos, pos) do
      []
    end

    # DDL
    alias Ecto.Migration.{Table, Index, Reference, Constraint}

    def execute_ddl({command, %Table{} = table, columns}) when command in [:create, :create_if_not_exists] do
      prefix = table.prefix || "dbo"
      table_structure =
        case column_definitions(table, columns) ++ pk_definitions(columns, ", CONSTRAINT [PK_#{prefix}_#{table.name}] ") do
          [] -> []
          list -> [" (#{list})"]
        end

      query = [[if_table_not_exists(command == :create_if_not_exists, table.name, prefix),
        "CREATE TABLE ",
        quote_table(prefix, table.name),
        table_structure,
        engine_expr(table.engine),
        options_expr(table.options),
        if_do(command == :create_if_not_exists, "END ")]]
      Enum.map_join(query, "", &"#{&1}")
    end

    def execute_ddl({command, %Table{} = table}) when command in [:drop, :drop_if_exists] do
      prefix = table.prefix || "dbo"
      query = [[if_table_exists(command == :drop_if_exists, table.name, prefix),
        "DROP TABLE ",
        quote_table(prefix, table.name),
        if_do(command == :drop_if_exists, "END ")]]
      Enum.map_join(query, "", &"#{&1}")
    end

    def execute_ddl({:alter, %Table{} = table, changes}) do
      prefix = table.prefix || "dbo"
      query = [["ALTER TABLE ", quote_table(prefix, table.name), " ",
        column_changes(table, changes),
        pk_definitions(changes, ", ADD CONSTRAINT [PK_#{prefix}_#{table.name}] ")]]
      Enum.map_join(query, "", &"#{&1}")
    end

    def execute_ddl({:create, %Index{} = index}) do
      prefix = index.prefix || "dbo"
      if index.where do
        error!(nil, "TDS adapter does not support where in indexes yet.")
      end

      query = [["CREATE", if_do(index.unique, " UNIQUE"), " INDEX ",
        quote_name(index.name),
        " ON ",
        quote_table(prefix, index.table), " ",
        "(#{intersperse_map(index.columns, ", ", &index_expr/1)})",
        if_do(index.using, [" USING ", to_string(index.using)]),
        if_do(index.concurrently, " LOCK=NONE")]]
      Enum.map_join(query, "", &"#{&1}")
    end

    def execute_ddl({:create_if_not_exists, %Index{}}),
      do: error!(nil, "TDS adapter does not support create if not exists for index")

    def execute_ddl({:create, %Constraint{check: check}}) when is_binary(check),
      do: error!(nil, "TDS adapter does not support check constraints")
    def execute_ddl({:create, %Constraint{exclude: exclude}}) when is_binary(exclude),
      do: error!(nil, "TDS adapter does not support exclusion constraints")

    def execute_ddl({:drop, %Index{} = index}) do
      prefix = index.prefix || "dbo"
      query = [["DROP INDEX ",
        quote_name(index.name),
        " ON ", quote_table(prefix, index.table),
        if_do(index.concurrently, " LOCK=NONE")]]
      Enum.map_join(query, "", &"#{&1}")
    end

    def execute_ddl({:drop, %Constraint{}}),
      do: error!(nil, "TDS adapter does not support constraints")

    def execute_ddl({:drop_if_exists, %Index{}}),
      do: error!(nil, "TDS adapter does not support drop if exists for index")

    def execute_ddl({:rename, %Table{} = current_table, %Table{} = new_table}) do
      current_table_prefix = current_table.prefix || "dbo"
      new_table_prefix = new_table.prefix || "dbo"
      query = [["exec sp_rename '", quote_table(current_table_prefix, current_table.name),
        "', '", quote_table(new_table_prefix, new_table.name). "'"]]
      Enum.map_join(query, "", &"#{&1}")
    end

    def execute_ddl({:rename, _table, _current_column, _new_column}) do
      error!(nil, "TDS adapter does not support renaming columns yet.")
    end

    def execute_ddl(string) when is_binary(string), do: [string]

    def execute_ddl(keyword) when is_list(keyword),
      do: error!(nil, "TDS adapter does not support keyword lists in execute")

    defp pk_definitions(columns, prefix) do
      pks =
        for {_, name, _, opts} <- columns,
            opts[:primary_key],
            do: name

      case pks do
        [] -> []
        _  -> [[prefix, "PRIMARY KEY CLUSTERED (#{intersperse_map(pks, ", ", &quote_name/1)})"]]
      end
    end

    defp column_definitions(table, columns) do
      intersperse_map(columns, ", ", &column_definition(table, &1))
    end

    defp column_definition(table, {:add, name, %Reference{} = ref, opts}) do
      [quote_name(name), " ", reference_column_type(ref.type, opts),
      column_options(opts), reference_expr(ref, table, name)]
    end

    defp column_definition(_table, {:add, name, type, opts}) do
      [quote_name(name), " ", column_type(type, opts), column_options(opts)]
    end

    defp column_changes(table, columns) do
      intersperse_map(columns, ", ", &column_change(table, &1))
    end

    defp column_change(table, {:add, name, %Reference{} = ref, opts}) do
      ["ADD ", quote_name(name), " ", reference_column_type(ref.type, opts),
      column_options(opts), constraint_expr(ref, table, name)]
    end

    defp column_change(_table, {:add, name, type, opts}) do
      ["ADD ", quote_name(name), " ", column_type(type, opts), column_options(opts)]
    end

    defp column_change(table, {:modify, name, %Reference{} = ref, opts}) do
      ["ALTER COLUMN ", quote_name(name), " ", reference_column_type(ref.type, opts),
      column_options(opts), constraint_expr(ref, table, name)]
    end

    defp column_change(_table, {:modify, name, type, opts}) do
      ["ALTER COLUMN ", quote_name(name), " ", column_type(type, opts), column_options(opts)]
    end

    defp column_change(_table, {:remove, name}), do: ["DROP ", quote_name(name)]

    defp column_options(opts) do
      default = Keyword.fetch(opts, :default)
      null    = Keyword.get(opts, :null)
      [default_expr(default), null_expr(null)]
    end

    defp null_expr(false), do: " NOT NULL"
    defp null_expr(true), do: " NULL"
    defp null_expr(_), do: []

    defp default_expr({:ok, nil}),
      do: " DEFAULT NULL"
    defp default_expr({:ok, literal}) when is_binary(literal),
      do: [" DEFAULT '", escape_string(literal), "'"]
    defp default_expr({:ok, literal}) when is_number(literal) or is_boolean(literal),
      do: [" DEFAULT ", to_string(literal)]
    defp default_expr({:ok, {:fragment, expr}}),
      do: [" DEFAULT ", expr]
    defp default_expr(:error),
      do: []

    defp index_expr(literal) when is_binary(literal),
      do: literal
    defp index_expr(literal), do: quote_name(literal)

    defp engine_expr(storage_engine),
      do: [""]

    defp options_expr(nil),
      do: []
    defp options_expr(keyword) when is_list(keyword),
      do: error!(nil, "TDS adapter does not support keyword lists in :options")
    defp options_expr(options),
      do: [" ", to_string(options)]

    defp column_type(type, opts) do
      size      = Keyword.get(opts, :size)
      precision = Keyword.get(opts, :precision)
      scale     = Keyword.get(opts, :scale)
      type_name = ecto_to_db(type)

      cond do
        size            -> [type_name, "(", to_string(size), ")"]
        precision       -> [type_name, "(", to_string(precision), ",", to_string(scale || 0), ")"]
        type == :string -> [type_name, "(255)"]
        true            -> type_name
      end
    end

    defp constraint_expr(%Reference{} = ref, table, name) do 
      Enum.map_join([", ADD CONSTRAINT ", reference_name(ref, table, name),
          " FOREIGN KEY (#{quote_name(name)})",
          " REFERENCES ", quote_table(table.prefix || "dbo", ref.table),
          "(#{quote_name(ref.column)})",
          reference_on_delete(ref.on_delete), reference_on_update(ref.on_update)], "", &"#{&1}")
    end

    defp reference_expr(%Reference{} = ref, table, name) do
      Enum.map_join([", CONSTRAINT ", reference_name(ref, table, name),
          " FOREIGN KEY (#{quote_name(name)})",
          " REFERENCES ", quote_table(table.prefix || "dbo", ref.table),
          "(#{quote_name(ref.column)})",
          reference_on_delete(ref.on_delete), reference_on_update(ref.on_update)], "", &"#{&1}")
    end

    defp reference_name(%Reference{name: nil}, table, column),
      do: quote_name("FK_#{table.prefix || "dbo"}_#{table.name}_#{column}")
    defp reference_name(%Reference{name: name}, _table, _column),
      do: quote_name(name)

    defp reference_column_type(:id, _opts),         do: "BIGINT"
    defp reference_column_type(:serial, _opts),     do: "INT"
    defp reference_column_type(:bigserial, _opts),  do: "BIGINT"
    defp reference_column_type(type, opts),         do: column_type(type, opts)

    defp reference_on_delete(:nilify_all), do: " ON DELETE SET NULL"
    defp reference_on_delete(:delete_all), do: " ON DELETE CASCADE"
    defp reference_on_delete(_), do: []

    defp reference_on_update(:nilify_all), do: " ON UPDATE SET NULL"
    defp reference_on_update(:update_all), do: " ON UPDATE CASCADE"
    defp reference_on_update(_), do: []

    ## Helpers

    defp get_source(query, sources, ix, source) do
      {expr, name, _schema} = elem(sources, ix)
      {expr || paren_expr(source, sources, query), name}
    end

    defp quote_name(name)
    defp quote_name(name) when is_atom(name),
      do: quote_name(Atom.to_string(name))
    defp quote_name(name) do
      if String.contains?(name, "[") or String.contains?(name, "]") do
        error!(nil, "bad field name #{inspect name} '[' and ']' are not permited")
      end
      "[#{name}]"
    end

    defp quote_table(nil, name),    do: quote_table(name)
    defp quote_table(prefix, name), do: Enum.map_join([quote_table(prefix), ".", quote_table(name)], "", &"#{&1}")

    defp quote_table(name) when is_atom(name),
      do: quote_table(Atom.to_string(name))
    defp quote_table(name) do
      if String.contains?(name, "[") or String.contains?(name, "]") do
        error!(nil, "bad table name #{inspect name} '[' and ']' are not permited")
      end
      "[#{name}]"
    end

    defp intersperse_map(list, separator, mapper, acc \\ [])
    defp intersperse_map([], _separator, _mapper, acc),
      do: acc
    defp intersperse_map([elem], _separator, mapper, acc),
      do: [acc | mapper.(elem)]
    defp intersperse_map([elem | rest], separator, mapper, acc),
      do: intersperse_map(rest, separator, mapper, [acc, mapper.(elem), separator])

    defp if_do(condition, value) do
      if condition, do: value, else: []
    end

    defp escape_string(value) when is_binary(value) do
      value
      |> :binary.replace("'", "''", [:global])
    end

    defp ecto_cast_to_db(type, query), do: ecto_to_db(type, query)

    defp ecto_to_db(type, query \\ nil)
    defp ecto_to_db({:array, _}, query),
      do: error!(query, "Array type is not supported by TDS")
    defp ecto_to_db(:id, _query),             do: "bigint"
    defp ecto_to_db(:serial, _query),         do: "int"
    defp ecto_to_db(:bigserial, _query),      do: "bigint"
    defp ecto_to_db(:binary_id, _query),      do: "uniqueidentifier"
    defp ecto_to_db(:boolean, _query),        do: "bit"
    defp ecto_to_db(:string, _query),         do: "nvarchar"
    defp ecto_to_db(:float, _query),          do: "float"
    defp ecto_to_db(:binary, _query),         do: "varbinary"
    defp ecto_to_db(:uuid, _query),           do: "uniqueidentifier"
    defp ecto_to_db(:map, _query),            do: "nvarchar(max)"
    defp ecto_to_db({:map, :string}, _query), do: "nvarchar(max)"
    defp ecto_to_db(:utc_datetime, _query),   do: "datetime2"
    defp ecto_to_db(:naive_datetime, _query), do: "datetime"
    defp ecto_to_db(other, _query),           do: Atom.to_string(other)

    defp assemble(list) do
      list
      |> List.flatten
      |> Enum.filter(&(&1 != nil))
      |> Enum.join(" ")
    end

    defp error!(nil, message) do
      raise ArgumentError, message
    end
    defp error!(query, message) do
      raise Ecto.QueryError, query: query, message: message
    end

    defp if_table_not_exists(condition, name, prefix \\ "dbo") do
      if condition do
        query_segment = ["IF NOT EXISTS ( ",
                        "SELECT * ",
                        "FROM [INFORMATION_SCHEMA].[TABLES] info ",
                        "WHERE info.[TABLE_NAME] = '#{name}' ",
                        "AND info.[TABLE_SCHEMA] = '#{prefix}' ",
                        ") BEGIN "]
        Enum.map_join(query_segment, "", &"#{&1}")
      else
        []
      end
    end

    defp if_table_exists(condition, name, prefix \\ "dbo") do
      if condition do
        query_segment = ["IF EXISTS ( ",
                        "SELECT * ",
                        "FROM [INFORMATION_SCHEMA].[TABLES] info ",
                        "WHERE info.[TABLE_NAME] = '#{name}' ",
                        "AND info.[TABLE_SCHEMA] = '#{prefix}' ",
                        ") BEGIN "]
        Enum.map_join(query_segment, "", &"#{&1}")
      else
        []
      end
    end

    def uuid(<<v1::32, v2::16, v3::16, v4::64>>) do
      <<v1::little-signed-32, v2::little-signed-16, v3::little-signed-16, v4::signed-64>>
    end
      
    end
end
