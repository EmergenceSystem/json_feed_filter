%%%-------------------------------------------------------------------
%%% @doc JSON Feed search agent (jsonfeed.org spec v1 and v1.1).
%%%
%%% Reads a list of JSON Feed URLs from json_feed_config.json, fetches
%%% each feed, and returns items whose title, url or summary matches
%%% the search query.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%   Site-specific filters extend json_feed_filter_app:base_capabilities():
%%%
%%% json_feed_config.json format:
%%%   { "json_feeds": ["https://example.com/feed.json", ...] }
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(json_feed_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"json_feed">>, <<"feeds">>,
                                      <<"news">>, <<"blog">>].

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(json_feed_filter, ?MODULE, #{
        capabilities => base_capabilities()
    }).

stop(_State) ->
    em_filter:stop_agent(json_feed_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    Feeds     = read_config(),
    StartTime = erlang:system_time(millisecond),
    search_feeds(Feeds, string:lowercase(Value), StartTime, Timeout * 1000, []).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Value, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

%%--------------------------------------------------------------------
%% Config
%%--------------------------------------------------------------------

read_config() ->
    case file:read_file("json_feed_config.json") of
        {ok, Bin} ->
            try json:decode(Bin) of
                #{<<"json_feeds">> := Feeds} when is_list(Feeds) -> Feeds;
                _ -> []
            catch _:_ -> [] end;
        _ -> []
    end.

%%--------------------------------------------------------------------
%% Feed iteration
%%--------------------------------------------------------------------

search_feeds([], _Query, _Start, _Timeout, Acc) ->
    lists:reverse(Acc);
search_feeds([FeedUrl | Rest], Query, Start, Timeout, Acc) ->
    case erlang:system_time(millisecond) - Start >= Timeout of
        true  -> lists:reverse(Acc);
        false ->
            NewAcc = fetch_and_filter_feed(FeedUrl, Query, Start, Timeout, Acc),
            search_feeds(Rest, Query, Start, Timeout, NewAcc)
    end.

fetch_and_filter_feed(FeedUrl, Query, Start, Timeout, Acc) ->
    Url = binary_to_list(FeedUrl),
    case httpc:request(get,
                       {Url, [{"Accept",
                               "application/feed+json, application/json"}]},
                       [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            try json:decode(Body) of
                Feed when is_map(Feed) ->
                    Items = maps:get(<<"items">>, Feed, []),
                    process_items(Items, Query, Start, Timeout, Acc);
                _ ->
                    Acc
            catch _:_ -> Acc end;
        _ ->
            Acc
    end.

%%--------------------------------------------------------------------
%% Item processing
%%--------------------------------------------------------------------

process_items([], _Query, _Start, _Timeout, Acc) ->
    Acc;
process_items([Item | Rest], Query, Start, Timeout, Acc) ->
    case erlang:system_time(millisecond) - Start >= Timeout of
        true  -> Acc;
        false ->
            NewAcc = case process_item(Item, Query) of
                {ok, Embryo} -> [Embryo | Acc];
                skip         -> Acc
            end,
            process_items(Rest, Query, Start, Timeout, NewAcc)
    end.

process_item(Item, Query) ->
    Title   = to_str(maps:get(<<"title">>,        Item, <<>>)),
    Url     = to_str(maps:get(<<"url">>,          Item,
                  maps:get(<<"id">>,              Item, <<>>))),
    Summary = to_str(maps:get(<<"content_text">>, Item,
                  maps:get(<<"summary">>,         Item,
                  maps:get(<<"content_html">>,    Item, <<>>)))),
    Matches =
        string:str(string:lowercase(Title),   Query) > 0 orelse
        string:str(string:lowercase(Url),     Query) > 0 orelse
        string:str(string:lowercase(Summary), Query) > 0,
    case Matches of
        true ->
            {ok, #{
                <<"properties">> => #{
                    <<"url">>    => list_to_binary(Url),
                    <<"title">>  => unicode:characters_to_binary(Title),
                    <<"resume">> => unicode:characters_to_binary(
                                       string:slice(Summary, 0, 300))
                }
            }};
        false ->
            skip
    end.

to_str(B) when is_binary(B) -> binary_to_list(B);
to_str(_)                   -> "".
