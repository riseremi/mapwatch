module Model
    exposing
        ( Model
        , Msg(..)
        , Progress
        , init
        , update
        , subscriptions
        , isProgressDone
        , progressDuration
        )

import Set
import Date
import Time
import Ports
import AnimationFrame
import Navigation
import Model.LogLine as LogLine
import Model.Zone as Zone
import Model.Instance as Instance
import Model.Visit as Visit
import Model.Run as Run
import Model.Route as Route exposing (Route)


type alias Flags =
    { loadedAt : Float
    , isBrowserSupported : Bool
    }


type alias Progress =
    Ports.Progress


type alias Config =
    { maxSize : Int }


type alias Model =
    { config : Config
    , isBrowserSupported : Bool
    , loadedAt : Date.Date
    , route : Route
    , progress : Maybe Progress
    , now : Date.Date
    , parseError : Maybe LogLine.ParseError
    , instance : Instance.State
    , runState : Run.State
    , runs : List Run.Run
    , lines : List String
    }


type Msg
    = Tick Date.Date
    | InputClientLogWithId String
    | InputMaxSize String
    | RecvLogLine String
    | RecvProgress Progress
    | Navigate Navigation.Location


initModel : Flags -> Route -> Model
initModel flags route =
    let
        loadedAt =
            Date.fromTime flags.loadedAt
    in
        { config = { maxSize = 20 }
        , isBrowserSupported = flags.isBrowserSupported
        , route = route
        , parseError = Nothing
        , progress = Nothing
        , loadedAt = loadedAt
        , now = loadedAt
        , instance = Instance.init
        , runState = Run.Empty
        , runs = []
        , lines = []
        }


init flags loc =
    ( initModel flags (Route.parse loc |> Debug.log "navigate:init"), Cmd.none )


updateLine : LogLine.Line -> Model -> Model
updateLine line model =
    let
        instance =
            Instance.update line model.instance

        visit =
            Visit.tryInit model.instance instance

        ( runState, lastRun ) =
            Run.update instance visit model.runState

        runs =
            case lastRun of
                Just lastRun ->
                    lastRun :: model.runs

                Nothing ->
                    model.runs
    in
        { model
            | instance = instance

            -- , visits = visit |> Maybe.map (\v -> v :: model.visits) |> Maybe.withDefault model.visits
            , runState = runState
            , runs = runs
        }


updateRawLine : String -> Model -> Model
updateRawLine raw model =
    -- *Only when debugging*, save all raw loglines.
    case model.route of
        Route.DebugDumpLines ->
            { model | lines = raw :: model.lines }

        _ ->
            model


tick : Date.Date -> Model -> Model
tick t model =
    let
        ( runState, lastRun ) =
            Run.tick t model.instance model.runState

        runs =
            case lastRun of
                Just lastRun ->
                    lastRun :: model.runs

                Nothing ->
                    model.runs
    in
        { model | now = t, runState = runState, runs = runs }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg ({ config } as model) =
    case msg of
        Tick t ->
            if model.progress |> Maybe.map isProgressDone |> Maybe.withDefault False then
                ( tick t model, Cmd.none )
            else
                ( { model | now = t }, Cmd.none )

        Navigate loc ->
            ( { model | route = Route.parse loc |> Debug.log "navigate" }, Cmd.none )

        InputClientLogWithId id ->
            ( model, Ports.inputClientLogWithId { id = id, maxSize = config.maxSize } )

        InputMaxSize s ->
            case String.toInt s of
                Ok s ->
                    ( { model | config = { config | maxSize = s } }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        RecvLogLine raw ->
            (case LogLine.parse raw of
                Ok line ->
                    model
                        |> updateLine line
                        |> updateRawLine raw

                Err err ->
                    { model | parseError = Just err }
            )
                |> \m -> ( m, Cmd.none )

        RecvProgress p ->
            { model | progress = Just p }
                |> (\m ->
                        if isProgressDone p then
                            tick (Date.fromTime p.updatedAt) m
                        else
                            m
                   )
                |> \m -> ( m, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Ports.logline RecvLogLine
        , Ports.progress RecvProgress

        -- Slow down animation, deliberately - don't eat poe's cpu
        -- , AnimationFrame.times (Tick << Date.fromTime)
        , Time.every (Time.second * 1) (Tick << Date.fromTime)
        ]


progressPercent : Progress -> Float
progressPercent { val, max } =
    toFloat val
        / toFloat max
        |> clamp 0 1


isProgressDone : Progress -> Bool
isProgressDone p =
    progressPercent p >= 1


progressDuration : Progress -> Time.Time
progressDuration p =
    p.updatedAt - p.startedAt
