-module(openpixie_tools_skills).
-export([schema/0, list_skills/1, load_skill/1]).

schema() ->
    [
        #{
            type => function,
            function => #{
                name => list_skills,
                description => <<"List available skills">>,
                parameters => #{type => object, properties => #{}, required => []}
            }
        },
        #{
            type => function,
            function => #{
                name => load_skill,
                description => <<"Load full content of a skill's SKILL.md">>,
                parameters => #{
                    type => object,
                    properties => #{
                        name => #{type => string, description => <<"Skill name">>}
                    },
                    required => [name]
                }
            }
        }
    ].

list_skills(_) ->
    RawSkills = openpixie_skills:list_skills(),
    Summaries = lists:map(fun({Name, _SkillRecord}) ->
        #{name => Name}
    end, RawSkills),
    #{success => true, skills => Summaries}.

load_skill(Args) ->
    Name = maps:get(<<"name">>, Args, maps:get(name, Args, <<"">>)),
    case openpixie_skills:load_skill(Name) of
        {ok, Content} -> #{success => true, content => Content, name => Name};
        {error, not_found} -> #{success => false, error => skill_not_found}
    end.