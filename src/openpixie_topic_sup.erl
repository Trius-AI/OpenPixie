-module(openpixie_topic_sup).
-behaviour(supervisor).

-export([start_link/0, start_topic/0, start_topic/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 5, period => 60},
    ChildSpec = #{id => openpixie_topic,
                  start => {openpixie_topic, start_link, []},
                  restart => transient,
                  shutdown => 300000,
                  type => worker,
                  modules => [openpixie_topic]},
    {ok, {SupFlags, [ChildSpec]}}.

start_topic() ->
    TopicId = generate_id(),
    start_topic(TopicId).
start_topic(TopicId) ->
    case supervisor:start_child(?MODULE, [TopicId]) of
        {ok, Pid} ->
            {ok, _} = openpixie_topic_store:register(TopicId, Pid),
            {ok, TopicId, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

generate_id() ->
    <<Int:64>> = crypto:strong_rand_bytes(8),
    integer_to_binary(Int, 36).