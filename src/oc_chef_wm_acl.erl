%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92-*-
%% ex: ts=4 sw=4 et
%% @author Douglas Triggs <doug@getchef.com>
%% Copyright 2014 Chef, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(oc_chef_wm_acl).

-include_lib("chef_wm/include/chef_wm.hrl").
-include_lib("oc_chef_wm.hrl").

% For getting out the ReqId for stats_hero:
-record(context, {reqid :: binary(),
                  otto_connection,
                  darklaunch = undefined}).

-mixin([{chef_wm_base, [content_types_accepted/2,
                        content_types_provided/2,
                        finish_request/2,
                        malformed_request/2,
                        ping/2,
                        post_is_create/2]}]).

-mixin([{?BASE_RESOURCE, [forbidden/2,
                          is_authorized/2,
                          service_available/2]}]).

%% chef_wm behaviour callbacks
-behaviour(chef_wm).
-export([
         auth_info/2,
         init/1,
         init_resource_state/1,
         malformed_request_message/3,
         request_type/0,
         validate_request/3
        ]).

-export([
         allowed_methods/2,
         from_json/2,
         to_json/2
        ]).

-define(DEFAULT_HEADERS, []).

init(Config) ->
    chef_wm_base:init(?MODULE, Config).

init_resource_state(Config) ->
    io:format("~n---init~n", []),
    AclType = ?gv(acl_object_type, Config),
    {ok, #acl_state{type = AclType}}.

request_type() ->
    "acl".

allowed_methods(Req, State) ->
    {['GET', 'PUT'], Req, State}.

validate_request('GET', Req, #base_state{chef_db_context = DbContext,
                                         organization_guid = OrgId,
                                         organization_name = OrgName,
                                         resource_state = #acl_state{type = Type} = 
                                             AclState} = State) ->
    io:format("---val ~p~n", ['GET']),
    validate_authz_id(Req, State, AclState, Type, OrgId, OrgName, DbContext);
validate_request('PUT', Req, #base_state{chef_db_context = DbContext,
                                         organization_guid = OrgId,
                                         organization_name = OrgName,
                                         resource_state = #acl_state{type = Type} = 
                                             AclState} = State) ->
    io:format("---val ~p~n", ['PUT']),
    Body = wrq:req_body(Req),
    {ok, Acl} = parse_binary_json(Body),
    validate_authz_id(Req, State, AclState#acl_state{acl_data = Acl}, Type, OrgId,
                      OrgName, DbContext).

validate_authz_id(Req, State, AclState, Type, OrgId, OrgName, DbContext) ->
    Name = case Type of
               organization ->
                   <<"organizations">>;
               NotOrganization ->
                   chef_wm_util:object_name(NotOrganization, Req)
           end,
    io:format("---val got name: ~p~n", [Name]),
    try
        AuthzId = case Type of
                      cookbook ->
                          fetch_cookbook_id(DbContext, Name, OrgName);
                      NotCookbook ->
                          fetch_id(NotCookbook, DbContext, Name, OrgId)
                  end,
        io:format("---val got authzId: ~p~n", [AuthzId]),
        AclState1 = AclState#acl_state{authz_id = AuthzId},
        % TODO: check on this: I'm not sure this is what we really want; IIRC,
        % access is controlled by the ACLs so that (1) superuser will not
        % always have access and (2) I think access for ordinary users is not
        % limited to orgs.  This might work in practice, though, if ReqId is
        % passed through?
        {Req, State#base_state{resource_state = AclState1,
                               superuser_bypasses_checks = true}}
    catch
        throw:{not_found, Name} ->
            Message = chef_wm_util:not_found_message(Type, Name),
            Req1 = chef_wm_util:set_json_body(Req, Message),
            {{halt, 404}, Req1, State#base_state{log_msg = acl_not_found}}
    end.

% TODO: don't like this; we only need the authz id, so grabbing complete
% objects is wasteful.  Also, this might be more suited to be moved to
% oc_chef_wm_util or something
fetch_id(organization, DbContext, Name, _OrgId) ->
    % This is actually a request for the default org container
    % TODO: (Or is it?  This is failing still)
    fetch_id(container, DbContext, Name, <<"00000000000000000000000000000000">>);
fetch_id(user, DbContext, Name, _OrgId) ->
    case chef_db:fetch(#chef_user{username = Name}, DbContext) of
        not_found ->
            throw({not_found, Name});
        #chef_user{authz_id = AuthzId} ->
            AuthzId
    end;
fetch_id(client, DbContext, Name, OrgId) ->
    case chef_db:fetch(#chef_client{org_id = OrgId, name = Name}, DbContext) of
        not_found ->
            throw({not_found, Name});
        #chef_client{authz_id = AuthzId} ->
            AuthzId
    end;
fetch_id(container, DbContext, Name, OrgId) ->
    case chef_db:fetch(#oc_chef_container{org_id = OrgId, name = Name}, DbContext) of
        not_found ->
            throw({not_found, Name});
        #oc_chef_container{authz_id = AuthzId} ->
            AuthzId
    end;
fetch_id(data_bag, DbContext, Name, OrgId) ->
    case chef_db:fetch(#chef_data_bag{org_id = OrgId, name = Name}, DbContext) of
        not_found ->
            throw({not_found, Name});
        #chef_data_bag{authz_id = AuthzId} ->
            AuthzId
    end;
fetch_id(node, DbContext, Name, OrgId) ->
    case chef_db:fetch(#chef_node{org_id = OrgId, name = Name}, DbContext) of
        not_found ->
            throw({not_found, Name});
        #chef_node{authz_id = AuthzId} ->
            AuthzId
    end;
fetch_id(role, DbContext, Name, OrgId) ->
    case chef_db:fetch(#chef_node{org_id = OrgId, name = Name}, DbContext) of
        not_found ->
            throw({not_found, Name});
        #chef_node{authz_id = AuthzId} ->
            AuthzId
    end;

fetch_id(group, #context{reqid = ReqId}, Name, OrgId) ->
    % Yes, this is ugly, but functionally it's identical to the internal logic
    % of a regular group fetch, minus expanding the group members and such.
    % And the regular group fetch was breaking for some reason I couldn't
    % figure out, and at least this avoids that and doesn't spent time on
    % extra requests
    case stats_hero:ctime(ReqId, {chef_sql, fetch},
                          fun() ->
                                  chef_object:default_fetch(#oc_chef_group{org_id = OrgId,
                                                                           name = Name},
                                                            fun chef_sql:select_rows/1)
                          end) of
        not_found ->
            throw({not_found, Name});
        #oc_chef_group{authz_id = AuthzId} ->
            AuthzId
    end;
fetch_id(environment, DbContext, Name, OrgId) ->
    case chef_db:fetch(#chef_environment{org_id = OrgId, name = Name}, DbContext) of
        not_found ->
            throw({not_found, Name});
        #chef_environment{authz_id = AuthzId} ->
            AuthzId
    end.

% TODO: bespoke code; cookbooks retrieval is by orgname instead of ID
fetch_cookbook_id(DbContext, Name, OrgName) ->
    % cookbook endpoint pattern is utterly different from the others, generic
    % fetch does not handle cookbooks (and, well, versioning)
    case chef_db:fetch_latest_cookbook_version(DbContext, OrgName, Name) of
        not_found ->
            throw({not_found, Name});
        {cookbook_exists, AuthzId} ->
            % unclear when this can happen; I assume for wrong version but
            % won't happen with 'latest' version?  But still checking for it
            % here.
            AuthzId;
        #chef_cookbook_version{authz_id = AuthzId} ->
            AuthzId
    end.

auth_info(Req, State) ->
    io:format("---auth info~n", []),
    % Don't fail yet; we only want to fetch the information once, so we'll
    % check for permission when we return/update the data

    % TODO: do we want to do it that way, or do we want to fetch the data now,
    % check and save it in the state instead?
    {authorized, Req, State}.

to_json(Req, #base_state{requestor_id = RequestorId,
                         resource_state = AclState} = State) ->
    io:format("---to json~n", []),
    case fetch(AclState, RequestorId) of
        forbidden ->
            {{halt, 403}, Req, State#base_state{log_msg = acl_not_found}};
        Ejson ->
            Json = chef_json:encode(Ejson),
            {Json, Req, State}
    end.

parse_binary_json(Body) ->
    {ok, chef_json:decode_body(Body)}.

% Translate types; in ACLs, everything is an object, actor, group, or container
acl_path(node, AuthzId) ->
    acl_path(object, AuthzId);
acl_path(role, AuthzId) ->
    acl_path(object, AuthzId);
acl_path(data_bag, AuthzId) ->
    acl_path(object, AuthzId);
acl_path(environment, AuthzId) ->
    acl_path(object, AuthzId);
acl_path(cookbook, AuthzId) ->
    acl_path(object, AuthzId);
acl_path(client, AuthzId) ->
    acl_path(actor, AuthzId);
acl_path(user, AuthzId) ->
    acl_path(actor, AuthzId);
acl_path(organization, AuthzId) ->
    acl_path(container, AuthzId);
acl_path(Type, AuthzId) ->
    "/" ++ atom_to_list(Type) ++ "s/" ++ binary_to_list(AuthzId) ++ "/acl".

fetch(#acl_state{type = Type, authz_id = AuthzId}, RequestorId) ->
    Path = acl_path(Type, AuthzId),
    io:format("---path: ~p~n", [Path]),
    Result = oc_chef_authz_http:request(Path, get, ?DEFAULT_HEADERS, [], RequestorId),
    io:format("---acl data: ~p~n", [Result]),
    case Result of 
        {ok, Record} ->
            ids_to_names(Record);
        {error, forbidden} ->
            forbidden;
        Other ->
            Other
    end.

convert_group_ids_to_names(AuthzIds) ->
    oc_chef_group:find_groups_names(AuthzIds, fun chef_sql:select_rows/1).

convert_actor_ids_to_names(AuthzIds) ->
    {ClientNames, RemainingAuthzIds} =
        oc_chef_group:find_clients_names(AuthzIds, fun chef_sql:select_rows/1),
    {UserNames, DefunctActorAuthzIds} =
        oc_chef_group:find_users_names(RemainingAuthzIds, fun chef_sql:select_rows/1),
    {ClientNames ++ UserNames, DefunctActorAuthzIds}.

process_part(Part, Record) ->
    io:format("---part: ~p~n", [Part]),
    Members = ej:get({Part}, Record),
    ActorIds = ej:get({<<"actors">>}, Members),
    GroupIds = ej:get({<<"groups">>}, Members),
    {ActorNames, DefunctActorAuthzIds} = convert_actor_ids_to_names(ActorIds),
    {GroupNames, DefunctGroupAuthzIds} = convert_group_ids_to_names(GroupIds),
    % We do this for groups, probably good to do it here too
    oc_chef_authz_cleanup:add_authz_ids(DefunctActorAuthzIds, DefunctGroupAuthzIds),
    Members1 = ej:set({<<"actors">>}, Members, ActorNames),
    Members2 = ej:set({<<"groups">>}, Members1, GroupNames),
    ej:set({Part}, Record, Members2).

ids_to_names(Record) ->
    Record1 = process_part(<<"create">>, Record),
    Record2 = process_part(<<"read">>, Record1),
    Record3 = process_part(<<"update">>, Record2),
    Record4 = process_part(<<"delete">>, Record3),
    process_part(<<"grant">>, Record4).

from_json(Req, #base_state{requestor_id = RequestorId,
                           organization_guid = OrgId,
                           resource_state = AclState} = State) ->
    io:format("---from json~n", []),
    case update_from_json(AclState, OrgId, RequestorId) of
        forbidden ->
            {{halt, 403}, Req, State#base_state{log_msg = acl_not_found}};
        _Other ->
            {true, Req, State}
    end.

update_from_json(#acl_state{type = Type, authz_id = AuthzId, acl_data = Data}, OrgId,
                 RequestorId) ->
    % This is probably dangerous (in that one type of permission could be
    % updated, and a future type could fail); however, I'm not sure what can
    % be really done about it.  It theoretically shouldn't happen in practice,
    % but you know what they say about theory and practice
    try
        update_part(<<"create">>, Data, Type, AuthzId, OrgId, RequestorId),
        update_part(<<"read">>, Data, Type, AuthzId, OrgId, RequestorId),
        update_part(<<"delete">>, Data, Type, AuthzId, OrgId, RequestorId),
        update_part(<<"update">>, Data, Type, AuthzId, OrgId, RequestorId),
        update_part(<<"grant">>, Data, Type, AuthzId, OrgId, RequestorId)
    catch
        throw:forbidden ->
            forbidden
    end.

convert_group_names_to_ids(GroupNames, OrgId) ->
    oc_chef_group:find_group_authz_ids(GroupNames, OrgId, fun chef_sql:select_rows/1).

convert_actor_names_to_ids(Names, OrgId) ->
    ClientIds = oc_chef_group:find_client_authz_ids(Names, OrgId,
                                                    fun chef_sql:select_rows/1),
    UserIds = oc_chef_group:find_user_authz_ids(Names, fun chef_sql:select_rows/1),
    ClientIds ++ UserIds.

names_to_ids(Ace, OrgId) ->
    ActorNames = ej:get({<<"actors">>}, Ace),
    GroupNames = ej:get({<<"groups">>}, Ace),
    ActorIds = convert_actor_names_to_ids(ActorNames, OrgId),
    GroupIds = convert_group_names_to_ids(GroupNames, OrgId),
    Ace1 = ej:set({<<"actors">>}, Ace, ActorIds),
    ej:set({<<"groups">>}, Ace1, GroupIds).

update_part(Part, AclRecord, Type, AuthzId, OrgId, RequestorId) ->
    io:format("---update part: ~p~n", [Part]),
    Slice = names_to_ids(ej:get({Part}, AclRecord), OrgId),
    Path = acl_path(Type, AuthzId) ++ "/" ++ Part,
    Result = oc_chef_authz_http:request(Path, put, ?DEFAULT_HEADERS, Slice, RequestorId),
    case Result of
        {error, forbidden} ->
            throw(forbidden);
        Other ->
            Other
    end.

malformed_request_message(Any, _Req, _State) ->
    error({unexpected_malformed_request_message, Any}).
