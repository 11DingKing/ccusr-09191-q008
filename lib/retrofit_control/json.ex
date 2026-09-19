defmodule RetrofitControl.Json do
  @moduledoc """
  零依赖的 JSON 编解码器，仅供本服务 HTTP 适配器与持久化使用。

  为了让 `mix test` 在离线、无外部依赖的环境下运行，核心服务不引入 Jason 等包；
  生产环境仍可通过 RetrofitControl.Platform 接入外部系统。
  对象统一解码为键为字符串的 map。
  """

  @spec decode(binary) :: {:ok, term} | {:error, binary}
  def decode(bin) when is_binary(bin) do
    try do
      with {value, rest} <- value(skip_ws(bin)) do
        case skip_ws(rest) do
          <<>> -> {:ok, value}
          other -> {:error, "unexpected trailing data: #{inspect(clip(other))}"}
        end
      end
    catch
      :throw, {:json_error, msg} -> {:error, msg}
    end
  end

  def decode!(bin) do
    case decode(bin) do
      {:ok, value} -> value
      {:error, msg} -> raise ArgumentError, "JSON decode error: #{msg}"
    end
  end

  @spec encode(term) :: binary
  def encode(nil), do: "null"
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(n) when is_integer(n), do: Integer.to_string(n)
  def encode(n) when is_float(n), do: Float.to_string(n)

  def encode(atom) when is_atom(atom), do: encode(Atom.to_string(atom))

  def encode(str) when is_binary(str) do
    ~s(") <> escape(str, <<>>) <> ~s(")
  end

  def encode(map) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> encode(to_string(k)) <> ":" <> encode(v) end)
      |> Enum.join(",")

    "{" <> pairs <> "}"
  end

  def encode(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &encode/1) <> "]"
  end

  defp escape(<<>>, acc), do: acc

  defp escape(<<?", rest::binary>>, acc), do: escape(rest, acc <> "\\\"")
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, acc <> "\\\\")
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, acc <> "\\n")
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, acc <> "\\r")
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, acc <> "\\t")
  defp escape(<<?\b, rest::binary>>, acc), do: escape(rest, acc <> "\\b")
  defp escape(<<?\f, rest::binary>>, acc), do: escape(rest, acc <> "\\f")

  defp escape(<<cp::utf8, rest::binary>>, acc) when cp < 0x20 do
    hex = cp |> Integer.to_string(16) |> String.pad_leading(4, "0")
    escape(rest, acc <> "\\u" <> hex)
  end

  defp escape(<<cp::utf8, rest::binary>>, acc) do
    escape(rest, <<acc::binary, cp::utf8>>)
  end

  # --- decoder ---

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(bin), do: bin

  defp clip(bin) when is_binary(bin), do: binary_part(bin, 0, min(byte_size(bin), 40))

  defp value(<<"null", rest::binary>>), do: {nil, rest}
  defp value(<<"true", rest::binary>>), do: {true, rest}
  defp value(<<"false", rest::binary>>), do: {false, rest}
  defp value(<<?", rest::binary>>), do: string(rest, <<>>)
  defp value(<<"{", rest::binary>>), do: object(skip_ws(rest), %{})
  defp value(<<"[", rest::binary>>), do: array(skip_ws(rest), [])
  defp value(<<c, _::binary>> = bin) when c == ?- or c in ?0..?9, do: number(bin)

  defp value(bin),
    do: throw({:json_error, "unexpected token: #{inspect(clip(bin))}"})

  defp string(<<?", rest::binary>>, acc), do: {acc, rest}

  defp string(<<"\\", c, rest::binary>>, acc) do
    case c do
      ?" -> string(rest, <<acc::binary, ?">>)
      ?\\ -> string(rest, <<acc::binary, ?\\>>)
      ?/ -> string(rest, <<acc::binary, ?/>>)
      ?n -> string(rest, <<acc::binary, ?\n>>)
      ?r -> string(rest, <<acc::binary, ?\r>>)
      ?t -> string(rest, <<acc::binary, ?\t>>)
      ?b -> string(rest, <<acc::binary, ?\b>>)
      ?f -> string(rest, <<acc::binary, ?\f>>)
      ?u ->
        {cp, rest2} = unicode_cp(rest)
        string(rest2, <<acc::binary, cp::utf8>>)
      _ -> throw({:json_error, "bad escape \\#{<<c>>}"})
    end
  end

  defp string(<<cp::utf8, rest::binary>>, acc), do: string(rest, <<acc::binary, cp::utf8>>)
  defp string(<<>>, _acc), do: throw({:json_error, "unterminated string"})

  defp unicode_cp(<<a1, a2, a3, a4, rest::binary>>) do
    cp = hex4(a1, a2, a3, a4)

    if cp in 0xD800..0xDBFF do
      case rest do
        <<"\\u", b1, b2, b3, b4, rest2::binary>> ->
          low = hex4(b1, b2, b3, b4)

          if low in 0xDC00..0xDFFF do
            {0x10000 + (cp - 0xD800) * 1024 + (low - 0xDC00), rest2}
          else
            throw({:json_error, "bad surrogate pair"})
          end

        _ ->
          throw({:json_error, "expected low surrogate"})
      end
    else
      {cp, rest}
    end
  end

  defp unicode_cp(_), do: throw({:json_error, "bad \\u escape"})

  defp hex4(a, b, c, d), do: hex(a) * 4096 + hex(b) * 256 + hex(c) * 16 + hex(d)

  defp hex(c) when c in ?0..?9, do: c - ?0
  defp hex(c) when c in ?a..?f, do: c - ?a + 10
  defp hex(c) when c in ?A..?F, do: c - ?A + 10
  defp hex(_), do: throw({:json_error, "invalid hex digit"})

  defp object(<<"}", rest::binary>>, map), do: {map, rest}

  defp object(<<?", rest::binary>>, map) do
    {key, rest1} = string(rest, <<>>)
    rest2 = skip_ws(rest1)

    rest3 =
      case rest2 do
        <<":", r::binary>> -> skip_ws(r)
        _ -> throw({:json_error, "expected ':' after object key"})
      end

    {val, rest4} = value(rest3)

    case skip_ws(rest4) do
      <<",", r::binary>> -> object(skip_ws(r), Map.put(map, key, val))
      <<"}", r::binary>> -> {Map.put(map, key, val), r}
      other -> throw({:json_error, "expected ',' or '}' got #{inspect(clip(other))}"})
    end
  end

  defp object(bin, _map), do: throw({:json_error, "bad object: #{inspect(clip(bin))}"})

  defp array(<<"]", rest::binary>>, list), do: {Enum.reverse(list), rest}

  defp array(bin, list) do
    {val, rest1} = value(bin)

    case skip_ws(rest1) do
      <<",", r::binary>> -> array(skip_ws(r), [val | list])
      <<"]", r::binary>> -> {Enum.reverse([val | list]), r}
      other -> throw({:json_error, "expected ',' or ']' got #{inspect(clip(other))}"})
    end
  end

  defp number(bin) do
    # 严格按 JSON 数字语法 int [ frac ] [ exp ] 解析；分隔符（, } ] 空白）不能被吞掉。
    {int_str, rest1} = int_part(bin, <<>>)
    {frac_str, rest2} = frac_part(rest1, <<>>)
    {exp_str, rest3} = exp_part(rest2, <<>>)

    int_val = String.to_integer(int_str)

    value =
      cond do
        frac_str != "" ->
          # 把 "1e3" 这类无小数点的指数补成合法浮点
          float_str = int_str <> frac_str <> if(exp_str == "", do: "", else: exp_str)

          f =
            if frac_str != "" do
              String.to_float(float_str)
            else
              int_val
            end

          apply_exp(f, exp_str)

        exp_str != "" ->
          apply_exp(int_val * 1.0, exp_str)

        true ->
          int_val
      end

    {value, rest3}
  rescue
    _ -> throw({:json_error, "bad number: #{inspect(clip(bin))}"})
  end

  defp apply_exp(f, ""), do: f

  defp apply_exp(f, <<_e, rest::binary>>) do
    n =
      case rest do
        <<"+", digits::binary>> -> String.to_integer(digits)
        <<"-", digits::binary>> -> -String.to_integer(digits)
        digits -> String.to_integer(digits)
      end

    f * :math.pow(10, n)
  end

  defp int_part(<<?-, rest::binary>>, <<>>), do: int_sign(rest, "-")
  defp int_part(<<c, rest::binary>>, <<>>) when c in ?0..?9, do: int_digits(rest, <<c>>)

  defp int_sign(<<c, rest::binary>>, sign) when c in ?0..?9,
    do: int_digits(rest, <<sign::binary, c>>)

  defp int_sign(_, _), do: throw({:json_error, "bad number sign"})

  defp int_digits(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: int_digits(rest, <<acc::binary, c>>)

  defp int_digits(rest, acc), do: {acc, rest}

  defp frac_part(<<?., c, rest::binary>>, <<>>) when c in ?0..?9,
    do: frac_digits(rest, <<?., c>>)

  defp frac_part(bin, <<>>), do: {"", bin}

  defp frac_digits(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: frac_digits(rest, <<acc::binary, c>>)

  defp frac_digits(rest, acc), do: {acc, rest}

  defp exp_part(<<e, sign, c, rest::binary>>, <<>>)
       when e in [?e, ?E] and sign in [?+, ?-] and c in ?0..?9,
       do: exp_digits(rest, <<e, sign, c>>)

  defp exp_part(<<e, c, rest::binary>>, <<>>) when e in [?e, ?E] and c in ?0..?9,
    do: exp_digits(rest, <<e, c>>)

  defp exp_part(bin, <<>>), do: {"", bin}

  defp exp_digits(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: exp_digits(rest, <<acc::binary, c>>)

  defp exp_digits(rest, acc), do: {acc, rest}
end
