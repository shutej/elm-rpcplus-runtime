module Rpc where

{-| This is a runtime to support rpcplus generated clients. Typical client
usage looks like this:

    import MyProtocol (..)
    import Rpc
    import Signal
    import WebSocket

    -- Request Signal
    rpcRequest : Signal.Channel Request
    rpcRequest = Signal.Channel NoRequest

    -- Response Signal
    rpcResponse : Signal.Signal Response
    rpcResponse = Rpc.connect protocol
        <| WebSocket.connect myUrl
        <| Signal.subscribe rpcRequest

    -- Send a request
    Signal.send rpcRequest NoRequest


# Usage
@docs connect, Transport
-}

import Array
import Dict
import Json.Decode
import Json.Decode ((:=))
import Json.Encode
import Result
import Signal
import Signal ((<~))

{-| Transport is generally provided by WebSocket.connect.  In the future this
same interface may support retry logic or other transports (for example,
Http-based transports).
-}
type alias Transport = Signal.Signal String -> Signal.Signal String

type alias Id = Int
type alias Error a = Result.Result String a
type alias JsonValue = Json.Encode.Value

-- dictEncode

dictEncode : (a -> JsonValue) -> Dict.Dict String a -> JsonValue
dictEncode encode dict =
    Dict.map (\_ value -> encode value) dict |> Dict.toList |> Json.Encode.object

-- dictDecoder

dictDecoder : Json.Decode.Decoder a -> Json.Decode.Decoder (Dict.Dict String a)
dictDecoder decoder =
    Json.Decode.oneOf
        [ Json.Decode.null Dict.empty
        , Json.Decode.dict decoder
        ]

-- arrayDecoder

arrayDecoder : Json.Decode.Decoder a -> Json.Decode.Decoder (Array.Array a)
arrayDecoder decoder =
    Json.Decode.oneOf
        [ Json.Decode.null Array.empty
        , Json.Decode.array decoder
        ]

-- arrayEncode

arrayEncode : (a -> JsonValue) -> Array.Array a -> JsonValue
arrayEncode encode array =
    Json.Encode.array (Array.map encode array)

-- nullDecoder

nullDecoder : Json.Decode.Decoder a -> Json.Decode.Decoder (Maybe a)
nullDecoder decoder =
    Json.Decode.oneOf
        [ Json.Decode.null Nothing
        , Json.Decode.map Just decoder
        ]

-- nullEncode

nullEncode : (a -> JsonValue) -> Maybe a -> JsonValue
nullEncode encode maybe =
    case maybe of
      Just value -> encode value
      Nothing -> Json.Encode.null

-- closeStream

closeStreamMethod : String
closeStreamMethod = "CloseStream"

closeStreamParams : JsonValue
closeStreamParams = Json.Encode.object []

-- isLastStreamResponseError

isLastStreamResponseError : Error a -> Bool
isLastStreamResponseError error =
    case error of
      Result.Err "EOS" -> True
      otherwise -> False

-- RequestEnvelope

type alias RequestEnvelope =
    { id     : Id
    , method : String
    , params : JsonValue
    }

encodeRequestEnvelope : RequestEnvelope -> JsonValue
encodeRequestEnvelope envelope =
    Json.Encode.object
            [ ("id"     , Json.Encode.int envelope.id)
            , ("method" , Json.Encode.string envelope.method)
            , ("params" , envelope.params)
            ]

requestEnvelope : Connection request response -> request -> Id -> RequestEnvelope
requestEnvelope driver request id =
    { id     = id
    , method = driver.method request
    , params = driver.params request
    }

-- ResponseEnvelope

type alias ResponseEnvelope =
    { id     : Id
    , result : Maybe JsonValue
    , error  : Maybe String
    }

responseEnvelopeDecoder : Json.Decode.Decoder ResponseEnvelope
responseEnvelopeDecoder =
    Json.Decode.object3 ResponseEnvelope
        ("id" := Json.Decode.int)
        (Json.Decode.maybe ("result" := Json.Decode.value))
        (Json.Decode.maybe ("error"  := Json.Decode.string))

decodeResponseEnvelope : ResponseEnvelope -> Json.Decode.Decoder a -> Error a
decodeResponseEnvelope envelope decoder =
    case (envelope.result, envelope.error) of
      (Just value, Nothing)    -> Json.Decode.decodeValue decoder value
      (Nothing   , Just error) -> Result.Err error

type alias Response input output =
    { id     : Id
    , input  : input
    , output : Error output
    }

-- Protocol

type alias Protocol request response =
    { method      : request -> String
    , params      : request -> JsonValue
    , noRequest   : request
    , noResponse  : response
    , closeStream : request -> Maybe Id
    , codec       : ResponseEnvelope -> request -> response
    , done        : response -> Bool
    }

-- Connection

type Action request
    = ClientInput request
    | ServerOutput String

type alias State request =
    { pendingRequest : Dict.Dict Id request
    , nextId         : Id
    }

type alias ConnectionMixin protocol request response =
    { protocol
    | serverChannel   : Signal.Channel String
    , responseChannel : Signal.Channel response
    , action          : Signal.Signal (Action request)
    , state           : State request
    }

type alias Connection request response = ConnectionMixin (Protocol request response) request response

stepClientInput : Connection request response -> request -> State request -> State request
stepClientInput driver request state =
    let
        (id, nextId) =
            case driver.closeStream request of
              Just id -> (id, state.nextId)
              Nothing -> (state.nextId, state.nextId + 1)
        _ =
            requestEnvelope driver request id
                |> encodeRequestEnvelope
                |> Json.Encode.encode 0
                |> Signal.send driver.serverChannel
    in
      { state | pendingRequest <- Dict.insert id request state.pendingRequest
              , nextId <- nextId }

stepServerOutput : Connection request response -> String -> State request -> State request
stepServerOutput driver output state =
    case Json.Decode.decodeString responseEnvelopeDecoder output of
      Result.Ok envelope ->
          case Dict.get envelope.id state.pendingRequest of
            Just request ->
                let
                    response = driver.codec envelope request
                    _ = Signal.send driver.responseChannel response
                in
                  if driver.done response
                  then { state | pendingRequest <- Dict.remove envelope.id state.pendingRequest }
                  else state

step : Connection request response -> Action request -> State request -> State request
step driver action state =
    case action of
      ClientInput input ->
          if input /= driver.noRequest
          then stepClientInput driver input state
          else state
      ServerOutput output ->
          stepServerOutput driver output state

{-| connect overlays a Protocol, which is type-safe, over a Transport, which
carries strings and is usually provided by WebSocket.connect.  The
resulting connection will read from the request signal and write to the
response signal.
-}
connect : Protocol request response -> Transport -> Signal.Signal request -> Signal.Signal response
connect protocol transport request =
    let
        serverChannel = Signal.channel ""
        responseChannel = Signal.channel protocol.noResponse
        -- TODO(shutej): Find a nicer syntax for updating multiple records.
        t1 = protocol
        t2 = { t1 | serverChannel = serverChannel }
        t3 = { t2 | responseChannel = responseChannel }
        t4 = { t3 | action = Signal.merge
                                  (ClientInput <~ request)
                                  (ServerOutput <~ transport (Signal.subscribe serverChannel)) }
        t5 = { t4 | state = { pendingRequest = Dict.empty, nextId = 0 } }
        connection = t5
        _ = Signal.foldp (step connection) connection.state connection.action
    in Signal.subscribe responseChannel
