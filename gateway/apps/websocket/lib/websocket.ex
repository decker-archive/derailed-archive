defmodule Derailed.WebSocket do
  @moduledoc """
  Process dedicated to handling WebSocket connections to the Gateway.
  """
  @behaviour :cowboy_websocket

  # non-process functions
  @spec validate_message(map(), map()) :: :ok | {:error, term()}
  defp validate_message(schema, message) do
    scheme = schema |> ExJsonSchema.Schema.resolve()

    case ExJsonSchema.Validator.validate(scheme, message) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp map_op(op) do
    %{
      # 0 => :dispatch
      # 1 => :hello,
      2 => :ready,
      # 3 => :resume,
      # 4 => :ping,
      5 => :ack
    }[op]
  end

  defp get_hb_interval do
    Enum.random(42_000..48_000)
  end

  @spec hb_timer(non_neg_integer()) :: reference()
  defp hb_timer(time) do
    :erlang.send_after(time + 2000, self(), :check_heartbeat)
  end

  @spec encode(struct(), :zlib.zstream() | nil) :: binary
  defp encode(term, compressor) do
    term = Derailed.Utilities.struct_to_map(term)

    inp = Jsonrs.encode!(term)

    if compressor != nil do
      :erlang.list_to_binary(:zlib.deflate(compressor, inp, :full))
    else
      inp
    end
  end

  @spec uncode(struct(), :zlib.zstream() | nil) :: {:binary, binary()} | {:text, binary()}
  defp uncode(term, compressor) do
    res = encode(term, compressor)

    if compressor != nil do
      {:binary, res}
    else
      {:text, res}
    end
  end

  @spec make_ready(String.t()) :: {:ok, Derailed.Payload.Ready} | {:error, term()}
  defp make_ready(token) do
    device_id = Derailed.Token.get_device_id(token)

    case Postgrex.prepare_execute(:db, "get_device", "SELECT * FROM devices WHERE id = $1;", [
           device_id
         ]) do
      {:ok, _query, result} ->
        device = Derailed.Utilities.map!(result)
        user_id = Map.get(device, "user_id")

        {_query, result} =
          Postgrex.prepare_execute!(:db, "get_user", "SELECT * FROM users WHERE id = $1", [
            user_id
          ])

        user = Derailed.Utilities.map!(result)
        # immediately drop the password
        user = Map.delete(user, "password")

        {_query, guild_ids_result} =
          Postgrex.prepare_execute!(
            :db,
            "get_user_guild_ids",
            "SELECT id FROM guilds WHERE id IN (SELECT guild_id FROM guild_members WHERE user_id = $1);",
            [user[:id]]
          )

        {_query, read_state_result} =
          Postgrex.prepare_execute!(
            :db,
            "get_read_states",
            "SELECT * FROM read_states WHERE user_id = $1;",
            [user[:id]]
          )

        {_query, relationship_result} =
          Postgrex.prepare_execute!(
            :db,
            "get_relationships",
            "SELECT target_user_id, relation FROM relationships WHERE origin_user_id = $1;",
            [user[:id]]
          )

        guild_ids = Derailed.Utilities.maps!(guild_ids_result)
        read_states = Derailed.Utilities.maps!(read_state_result)
        relationships = Derailed.Utilities.maps!(relationship_result)

        session_id = Derailed.Token.make_ulid()

        {:ok, session_pid} =
          GenRegistry.start(
            Derailed.Session,
            session_id,
            [
              session_id,
              user_id,
              guild_ids,
              self()
            ]
          )

        Derailed.Session.start(session_pid)

        {:ok,
         %Derailed.Payload.Ready{
           session_id: session_id,
           user: user,
           guild_ids: guild_ids,
           read_states: read_states,
           relationships: relationships
         }, session_id, session_pid}

      {:error, _reason} ->
        {:error, :invalid_token}
    end
  end

  # cowboy functions

  def init(req, _state) do
    {:cowboy_websocket, req, %{}}
  end

  def websocket_init(_state) do
    heartbeat_interval = get_hb_interval()
    heartbeat_ref = hb_timer(heartbeat_interval)

    {:reply,
     uncode(
       %Derailed.Payload.Base{
         op: 1,
         s: 0,
         d: %Derailed.Payload.Hello{
           heartbeat_interval: heartbeat_interval
         }
       },
       nil
     ),
     %State{
       session_id: nil,
       session_pid: nil,
       user_id: nil,
       # TODO: implement
       intents: 0,
       sequence: 0,
       zlib_enabled: false,
       heartbeat_interval: heartbeat_interval,
       heartbeat_ref: heartbeat_ref,
       presence: nil,
       compressor: nil
     }}
  end

  # TODO: rate limiting, 60 frames per minute.
  def websocket_handle({:text, content}, state) do
    case Jsonrs.decode(content) do
      {:ok, message} ->
        if not is_map(message) do
          {:close, 5001, "Frames sent must be maps"}
        end

        op_code = Map.get(message, "op")

        if op_code != nil or not is_integer(op_code) do
          {:close, 5002, "Invalid Op Code"}
        end

        op({map_op(op_code), message}, state)

      {:error, _reason} ->
        {:close, 5000, "Invalid JSON payload sent"}
    end
  end

  def websocket_handle(_any_frame, state) do
    {:ok, state}
  end

  # op code handling

  defp op({:ready, message}, state) do
    # TODO: client & library information property collection.
    case validate_message(
           %{
             "type" => "object",
             "properties" => %{
               "op" => %{
                 "type" => "integer"
               },
               "d" => %{
                 "type" => "object",
                 "properties" => %{
                   "token" => %{
                     "type" => "string"
                   },
                   "compress" => %{
                     "type" => "boolean",
                     "default" => false
                   }
                 },
                 "required" => [
                   "token"
                 ]
               },
               "required" => [
                 "op",
                 "d"
               ]
             }
           },
           message
         ) do
      {:error, reason} ->
        {:close, 5003, Jsonrs.encode!(reason)}

      :ok ->
        data = Map.get(message, "d")
        token = Map.get(data, "token")
        compress = Map.get(data, "compress")

        state =
          if compress do
            Map.put(state, "compressor", :zlib.open())
          else
            state
          end

        case make_ready(token) do
          {:ok, ready, session_id, session_pid} ->
            {:reply, uncode(ready, state.compressor),
             %{state | "session_id" => session_id, "session_pid" => session_pid}}

          {:error, reason} ->
            {:close, 5004, Jsonrs.encode!(reason)}
        end
    end
  end

  def websocket_info(message, state) do
    case message.t do
      "USER_DELETE" ->
        GenRegistry.stop(Derailed.Session, state.session_id)
        GenRegistry.stop(Derailed.Unify, state.user_id)
        {:close, 5005, "User has been deleted"}

      _ ->
        message = Map.put(message, "op", 0)
        {:reply, uncode(message, state.compressor), state}
    end
  end
end