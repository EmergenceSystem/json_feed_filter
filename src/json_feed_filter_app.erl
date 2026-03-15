%%%-------------------------------------------------------------------
%%% @doc JSON Feed search agent (jsonfeed.org spec v1 and v1.1).
%%%
%%% Reads a list of JSON Feed URLs from json_feed_config.json, fetches
%%% each feed, and returns items whose title, url or summary matches
%%% the search query.
%%%
%%% JSON Feed is the modern successor to RSS/Atom — same concept but
%%% pure JSON. No XML parser needed.
%%%
%%% Spec: https://jsonfeed.org/version/1.1
%%%
%%% json_feed_config.json format:
%%%   { "json_feeds": ["https://example.com/feed.json", ...] }
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, NewMemory}.
%%% Memory schema: #{seen => #{binary_url => true}}.
%%% @end
%%%-------------------------------------------------------------------
-module(json_feed_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2]).

-define(CAPABILITIES, [
    <<"json_feed">>,
    <<"feeds">>,
    <<"news">>,
    <<"blog">>
]).

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(json_feed_filter, ?MODULE, #{
        capabilities => ?CAPABILITIES,
        memory       => ets
    }).

stop(_State) ->
    em_filter:stop_agent(json_feed_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    Seen    = maps:get(seen, Memory, #{}),
    Embryos = generate_embryo_list(Body),
    Fresh   = [E || E <- Embryos, not maps:is_key(url_of(E), Seen)],
    NewSeen = lists:foldl(fun(E, Acc) ->
        Acc#{url_of(E) => true}
    end, Seen, Fresh),
    {Fresh, Memory#{seen => NewSeen}};

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
    case httpc:request(get, {Url, [{"Accept", "application/feed+json, application/json"}]},
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
    %% content_text is preferred over content_html (no HTML to strip).
    %% Fall back to summary if neither is present.
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

%%====================================================================
%% Internal helpers
%%====================================================================

to_str(B) when is_binary(B) -> binary_to_list(B);
to_str(_)                   -> "".

-spec url_of(map()) -> binary().
url_of(#{<<"properties">> := #{<<"url">> := Url}}) -> Url;
url_of(_) -> <<>>.
