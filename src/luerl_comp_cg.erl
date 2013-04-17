%% Copyright (c) 2013 Robert Virding
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% File    : luerl_comp_cg.erl
%% Author  : Robert Virding
%% Purpose : A basic LUA 5.2 compiler for Luerl.

%% Does code generation in the compiler.

-module(luerl_comp_cg).

-include("luerl.hrl").
-include("luerl_comp.hrl").
-include("luerl_instrs.hrl").

-export([chunk/2]).

-import(ordsets, [add_element/2,is_element/2,union/1,union/2,
		  subtract/2,intersection/2,new/0]).

%% chunk(St0, Opts) -> {ok,St0}.

chunk(#code{code=C0}=Code, Opts) ->
    {Is,nul} = exp(C0, true, nul),		%No local state
    luerl_comp:debug_print(Opts, "cg: ~p\n", [Is]),
    {ok,Code#code{code=Is}}.

%% set_var(Var) -> SetIs.
%% get_var(Var) -> GetIs.
%%  These return a LIST of instructions for setting/getting variable.

set_var(#lvar{d=D,i=I}) -> [?STORE_LVAR(D, I)];
set_var(#evar{d=D,i=I}) -> [?STORE_EVAR(D, I)];
set_var(#gvar{n=N}) -> [?STORE_GVAR(N)].

get_var(#lvar{d=D,i=I}) -> [?LOAD_LVAR(D, I)];
get_var(#evar{d=D,i=I}) -> [?LOAD_EVAR(D, I)];
get_var(#gvar{n=N}) -> [?LOAD_GVAR(N)].

%% stmt(Stmts, State) -> {Istmts,State}.

stmts([S0|Ss0], St0) ->
    {S1,St1} = stmt(S0, nul, St0),
    %% io:format("ss1: ~p\n", [{Loc0,Free0,Used0}]),
    {Ss1,St2} = stmts(Ss0, St1),
    {S1 ++ Ss1,St2};
stmts([], St) -> {[],St}.

%% stmt(Stmt, LocalVars, State) -> {Istmt,State}.

stmt(#assign_stmt{}=A, _, St) -> assign_stmt(A, St);
stmt(#call_stmt{}=C, _, St) -> call_stmt(C, St);
stmt(#return_stmt{}=R, _, St) -> return_stmt(R, St);
stmt(#break_stmt{}, _, St) -> {[?BREAK],St};
stmt(#block_stmt{}=B, _, St) -> block_stmt(B, St);
stmt(#while_stmt{}=W, _, St) -> while_stmt(W, St);
stmt(#repeat_stmt{}=R, _, St) -> repeat_stmt(R, St);
stmt(#if_stmt{}=I, _, St) -> if_stmt(I, St);
stmt(#nfor_stmt{}=F, _, St) -> numfor_stmt(F, St);
stmt(#gfor_stmt{}=F, _, St) -> genfor_stmt(F, St);
stmt(#local_assign_stmt{}=L, _, St) ->
    local_assign_stmt(L, St);
stmt(#local_fdef_stmt{}=L, _, St) ->
    local_fdef_stmt(L, St);
stmt(#expr_stmt{}=E, _, St) ->
    expr_stmt(E, St).

%% assign_stmt(Assign, State) -> {AssignIs,State}.

assign_stmt(#assign_stmt{vs=Vs,es=Es}, St) ->
    assign_loop(Vs, Es, St).

%% assign_loop(Vars, Exps, State) -> {Iassigns,State}.
%%  Must be careful with pushing and popping values here. Make sure
%%  all non-last values are singleton.
%%  This could most likely be folded together with assign_local_loop/3.

assign_loop([V], [E], St0) ->			%Remove unnecessary ?PUSH_VALS
    {Ie,St1} = exp(E, true, St0),		%Last argument to one variable
    {Iv,St2} = var(V, St1),
    {Ie ++ Iv,St2};
assign_loop([V|Vs], [E], St0) ->
    {Ie,St1} = exp(E, false, St0),		%Last argument to rest of vars
    {Ias,St2} = assign_loop_var(Vs, 1, St1),
    {Iv,St3} = var(V, St2),
    {Ie ++ Ias ++ Iv,St3};
assign_loop([V|Vs], [E|Es], St0) ->
    {Ie,St1} = exp(E, true, St0),		%Not last argument!
    {Ias,St2} = assign_loop(Vs, Es, St1),
    {Iv,St3} = var(V, St2),
    {Ie ++ [?PUSH] ++ Ias ++ [?POP] ++ Iv,St3};
assign_loop([], Es, St) ->
    assign_loop_exp(Es, St).

assign_loop_var([V|Vs], Vc, St0) ->
    {Ias,St1} = assign_loop_var(Vs, Vc+1, St0),
    {Iv,St2} = var(V, St1),
    {Ias ++ Iv ++ [?POP],St2};
assign_loop_var([], Vc, St) ->
    {[?PUSH_VALS(Vc-1)],St}.			%Last in acc

assign_loop_exp([E|Es], St0) ->
    {Ie,St1} = exp(E, false, St0),		%It will be dropped anyway
    {Ias,St2} = assign_loop_exp(Es, St1),
    {Ie ++ Ias,St2};
assign_loop_exp([], St) -> {[],St}.

var(#dot{e=Exp,r=Rest}, St0) ->
    {Ie,St1} = prefixexp_first(Exp, true, St0),
    {Ir,St2} = var_rest(Rest, St1),
    {[?PUSH] ++ Ie ++ Ir,St2};			%Save acc
var(V, St) ->
    {set_var(V),St}.

var_rest(#dot{e=Exp,r=Rest}, St0) ->
    {Ie,St1} = prefixexp_element(Exp, true, St0),
    {Ir,St2} = var_rest(Rest, St1),
    {Ie ++ Ir,St2};
var_rest(Exp, St) -> var_last(Exp, St).

var_last(#key{k=#lit{v=K}}, St) ->
    {[?SET_LIT_KEY(K)],St};			%[?PUSH,?LOAD_LIT(K),?SET_KEY]
var_last(#key{k=Exp}, St0) ->
    {Ie,St1} = exp(Exp, true, St0),
    {[?PUSH] ++ Ie ++ [?SET_KEY],St1}.

%% call_stmt(Call, State) -> {CallIs,State}.

call_stmt(#call_stmt{call=Exp}, St0) ->
    {Ie,St1} = exp(Exp, false, St0),
    {Ie,St1}.

%% return_stmt(Return, State) -> {ReturnIs,State}.

return_stmt(#return_stmt{es=Es}, St0) ->
    {Ies,St1} = explist(Es, false, St0),
    {Ies ++ [?RETURN(length(Es))],St1}.

%% block_stmt(Block, State) -> {BlockIs,State}.

block_stmt(#block_stmt{ss=Ss,lsz=Lsz,esz=Esz}, St0) ->
    {Iss,St1} = stmts(Ss, St0),
    {[?BLOCK(Lsz, Esz, Iss)],St1}.

%% do_block(Block, State) -> {Block,State}.
%%  Do_block never returns external new variables. Fits into stmt().

do_block(#block{ss=Ss,lsz=Lsz,esz=Esz}, St0) ->
    {Iss,St1} = stmts(Ss, St0),
    {[?BLOCK(Lsz, Esz, Iss)],St1}.

%% while_stmt(While, State) -> {WhileIs,State}.

while_stmt(#while_stmt{e=E,b=B}, St0) ->
    {Ie,St1} = exp(E, true, St0),
    {Ib,St2} = do_block(B, St1),
    {[?WHILE(Ie, Ib)],St2}.

%% repeat_stmt(Repeat, State) -> {RepeatIs,State}.

repeat_stmt(#repeat_stmt{b=B}, St0) ->
    {Ib,St1} = do_block(B, St0),
    {[?REPEAT(Ib)],St1}.

%% if_stmt(If, State) -> {If,State}.

if_stmt(#if_stmt{tests=Ts,else=E}, St) ->
    if_tests(Ts, E, St).

if_tests([{E,B}|Ts], Else, St0) ->
    {Ie,St1} = exp(E, true, St0),
    {Ib,St2} = do_block(B, St1),
    {Its,St3} = if_tests(Ts, Else, St2),
    {Ie ++ [?IF(Ib, Its)],St3};
if_tests([], Else, St0) ->
    {Ie,St1} = do_block(Else, St0),
    {Ie,St1}.

%% numfor_stmt(For, State) -> {ForIs,State}.

numfor_stmt(#nfor_stmt{v=V,init=I,limit=L,step=S,b=B}, St0) ->
    {Ies,St1} = explist([I,L,S], true, St0),
    {Ib,St2} = do_block(B, St1),
    [?BLOCK(Lsz, Esz, Is)] = Ib,
    ForBlock = [?BLOCK(Lsz, Esz, set_var(V) ++ Is)],
    {Ies ++ [?NFOR(V,ForBlock)],St2}.

%% %% An experiment to put the block *outside* the for loop.
%% numfor_stmt(#nfor_stmt{v=V,init=I,limit=L,step=S,b=B}, St0) ->
%%     {Ies,St1} = explist([I,L,S], true, St0),
%%     {Ib,St2} = do_block(B, St1),
%%     [?BLOCK(Lsz, Esz, Is)] = Ib,
%%     ForBlock = [?BLOCK(Lsz, Esz, [?NFOR(V,set_var(V) ++ Is)])],
%%     {Ies ++ ForBlock,St2}.

%% genfor_stmt(For, State) -> {ForIs,State}.

genfor_stmt(#gfor_stmt{vs=[V|Vs],gens=Gs,b=B}, St0) ->
    {Igs,St1} = explist(Gs, false, St0),
    {Ias,St2} = assign_local_loop_var(Vs, 1, St1),
    {Ib,St3} = do_block(B, St2),
    [?BLOCK(Lsz, Esz, Is)] = Ib,
    ForBlock = [?BLOCK(Lsz, Esz, Ias ++ set_var(V) ++ Is)],
    {Igs ++ [?POP_VALS(length(Gs)-1)] ++ [?GFOR(Vs,ForBlock)],St3}.

%% local_assign_stmt(Local, State) -> {Ilocal,State}.

local_assign_stmt(#local_assign_stmt{vs=Vs,es=Es}, St) ->
    assign_local(Vs, Es, St).

assign_local([V|Vs], [], St0) ->
    {Ias,St1} = assign_local_loop_var(Vs, 1, St0),
    {[?LOAD_LIT([])] ++ Ias ++ set_var(V),St1};
assign_local(Vs, Es, St) ->
    assign_local_loop(Vs, Es, St).

local_fdef_stmt(#local_fdef_stmt{v=V,f=F}, St0) ->
    {If,St1} = functiondef(F, St0),
    {If ++ set_var(V),St1}.

%% assign_local_loop(Vars, Exps, State) -> {Iassigns,State}.
%%  Must be careful with pushing and popping values here. Make sure
%%  all non-last values are singleton.
%%  This could most likely be folded together with assign_loop/3.

assign_local_loop([V], [E], St0) ->		%Remove unnecessary ?PUSH_VALS
    {Ie,St1} = exp(E, true, St0),		%Last argument to one variable!
    {Ie ++ set_var(V),St1};
assign_local_loop([V|Vs], [E], St0) ->
    {Ie,St1} = exp(E, false, St0),		%Last argument to many vars!
    {Ias,St2} = assign_local_loop_var(Vs, 1, St1),
    {Ie ++ Ias ++ set_var(V),St2};
    %%{Ie ++ [puss1] ++ Ias ++ [popp1|set_var(V)],St2};
assign_local_loop([V|Vs], [E|Es], St0) ->
    {Ie,St1} = exp(E, true, St0),		%Not last argument!
    {Ias,St2} = assign_local_loop(Vs, Es, St1),
    {Ie ++ [?PUSH] ++ Ias ++ [?POP|set_var(V)],St2};
assign_local_loop([], Es, St) ->
    assign_local_loop_exp(Es, St).

%% This expects a surrounding setting a variable, otherwise excess ?POP.
assign_local_loop_var([V|Vs], Vc, St0) ->
    {Ias,St1} = assign_local_loop_var(Vs, Vc+1, St0),
    {Ias ++ set_var(V) ++ [?POP],St1};
assign_local_loop_var([], Vc, St) ->
    {[?PUSH_VALS(Vc-1)],St}.			%Last in Acc

assign_local_loop_exp([E|Es], St0) ->
    {Ie,St1} = exp(E, false, St0),		%It will be dropped anyway
    {Ias,St2} = assign_local_loop_exp(Es, St1),
    {Ie ++ Ias,St2};
assign_local_loop_exp([], St) -> {[],St}.

%% expr_stmt(Expr, State) -> {ExprIs,State}.
%%  The expression pseudo statement. This will return a single value.
expr_stmt(#expr_stmt{exp=Exp}, St0) ->
    {Ie,St1} = exp(Exp, true, St0),
    {Ie,St1}.

%% explist(Exprs, State) -> {Instrs,State}.
%% explist(Exprs, SingleValue, State) -> {Instrs,State}.
%% exp(Expr, SingleValue, State) -> {Instrs,State}.
%%  Single determines if we are to only return the first value of a
%%  list of values. Single false makes us a return a list!

explist([E], S, St) -> exp(E, S, St);		%Append values to output?
explist([E|Es], S, St0) ->
    {Ie,St1} = exp(E, true, St0),
    {Ies,St2} = explist(Es, S, St1),
    {Ie ++ [?PUSH] ++ Ies,St2};
explist([], _, St) -> {[],St}.			%No expressions at all

exp(#lit{v=L}, S, St) ->
    Is = [?LOAD_LIT(L)],
    {multiple_values(S, Is),St};
exp(#fdef{}=F, S, St0) ->
    {If,St1} = functiondef(F, St0),
    {multiple_values(S, If), St1};
exp(#op{op='and',as=[A1,A2]}, S, St0) ->
    {Ia1,St1} = exp(A1, S, St0),
    {Ia2,St2} = exp(A2, S, St1),
    {Ia1 ++ [?IF_TRUE(Ia2)],St2};		%Must handle single/multiple
exp(#op{op='or',as=[A1,A2]}, S, St0) ->
    {Ia1,St1} = exp(A1, S, St0),
    {Ia2,St2} = exp(A2, S, St1),
    {Ia1 ++ [?IF_FALSE(Ia2)],St2};		%Must handle single/multiple
exp(#op{op=Op,as=As}, S, St0) ->
    {Ias,St1} = explist(As, true, St0),
    Iop = Ias ++ [?OP(Op,length(As))],
    {multiple_values(S, Iop),St1};
exp(#tc{fs=Fs}, S, St0) ->
    {Its,Fc,I,St1} = tableconstructor(Fs, St0),
    {Its ++ multiple_values(S, [?BUILD_TAB(Fc,I)]),St1};
exp(#lvar{n= <<"...">>}=V, S, St) ->		%Can be either local or frame
    {single_value(S, get_var(V)),St};
exp(#evar{n= <<"...">>}=V, S, St) ->
    {single_value(S, get_var(V)),St};
exp(E, S, St) ->
    prefixexp(E, S, St).

%% single_value(Single, Instrs) -> Instrs.
%% multiple_values(Single, Instrs) -> Instrs.
%%  Ensure either single value or multiple value.

single_value(true, Is) -> Is ++ [?SINGLE];
single_value(false, Is) -> Is.

multiple_values(true, Is) -> Is;
multiple_values(false, Is) -> Is ++ [?MULTIPLE].

%% prefixexp(Expr, SingleValue, State) -> {Instrs,State}.
%% prefixexp_rest(Expr, SingleValue, State) -> {Instrs,State}.
%% prefixexp_first(Expr, SingleValue, State) -> {Instrs,State}.
%% prefixexp_element(Expr, SingleValue, State) -> {Instrs,State}.
%%  Single determines if we are to only return the first value of a
%%  list of values. Single false makes us a return a list!

prefixexp(#dot{e=Exp,r=Rest}, S, St0) ->
    {Ie,St1} = prefixexp_first(Exp, true, St0),
    {Ir,St2} = prefixexp_rest(Rest, S, St1),
    {Ie ++ Ir,St2};
prefixexp(Exp, S, St) -> prefixexp_first(Exp, S, St).

prefixexp_first(#single{e=E}, S, St0) ->
    {Ie,St1} = exp(E, true, St0),		%Will make it single
    {multiple_values(S, Ie),St1};
prefixexp_first(Var, S, St) ->
    {multiple_values(S, get_var(Var)),St}.

prefixexp_rest(#dot{e=Exp,r=Rest}, S, St0) ->
    {Ie,St1} = prefixexp_element(Exp, true, St0),
    {Ir,St2} = prefixexp_rest(Rest, S, St1),
    {Ie ++ Ir,St2};
prefixexp_rest(Exp, S, St) -> prefixexp_element(Exp, S, St).

prefixexp_element(#key{k=#lit{v=K}}, S, St) ->
    {multiple_values(S, [?GET_LIT_KEY(K)]),St};	%Table is in Acc
prefixexp_element(#key{k=E}, S, St0) ->
    {Ie,St1} = exp(E, true, St0),		%Table is in Acc
    {[?PUSH] ++ Ie ++ multiple_values(S, [?GET_KEY]),St1};
prefixexp_element(#fcall{as=[]}, S, St) ->
    Ifs = [?CALL(0)],
    {single_value(S, Ifs),St};			%Function call returns list
prefixexp_element(#fcall{as=As}, S, St0) ->
    {Ias,St1} = explist(As, false, St0),
    Ifs = [?PUSH] ++ Ias ++ [?CALL(length(As))],
    {single_value(S, Ifs),St1};			%Function call returns list
prefixexp_element(#mcall{m=#lit{v=K},as=[]}, S, St) ->
    %% Special case this to leave table in the acc.
    Ims = [?PUSH,				%Push table onto stack
	   ?GET_LIT_KEY(K),			%Get function into acc
	   ?SWAP,				%Swap func/table in stack/acc
	   ?MULTIPLE] ++			%Make last argument
	[?CALL(1)],
    {single_value(S, Ims),St};			%Method call returns list
prefixexp_element(#mcall{m=#lit{v=K},as=As}, S, St0) ->
    {Ias,St1} = explist(As, false, St0),
    Ims = [?PUSH,				%Push table onto stack
	   ?GET_LIT_KEY(K),			%Get function into acc
	   ?SWAP,				%Swap func/table in stack/acc
	   ?PUSH] ++				%Push table as first arg
	Ias ++ [?CALL(length(As)+1)],
    {single_value(S, Ims),St1}.			%Method call returns list

%% functiondef(Func, State) -> {Func,State}.

functiondef(#fdef{ps=Ps0,ss=Ss,lsz=Lsz,esz=Esz}, St0) ->
    Ps1 = func_pars(Ps0),
    {Iss,St1} = stmts(Ss, St0),
    {[?FDEF(Lsz,Esz,Ps1,Iss)],St1}.

func_pars([#evar{n= <<"...">>,i=I}]) -> -I;	%Tail is index for varargs
func_pars([#lvar{n= <<"...">>,i=I}]) -> I;
func_pars([#evar{i=I}|Ps]) -> [-I|func_pars(Ps)];
func_pars([#lvar{i=I}|Ps]) -> [I|func_pars(Ps)];
func_pars([]) -> [].				%No varargs

%% tableconstructor(Fields, State) -> {Ifields,FieldCount,Index,State}.
%%  FieldCount is how many Key/Value pairs are on the stack, Index is
%%  the index of the next value in the acc.

tableconstructor(Fs, St0) ->
    {Its,Fc,I,St1} = tc_fields(Fs, 0.0, St0),
    {Its,Fc,I,St1}.

tc_fields([#efield{v=V}], I0, St0) ->
    I1 = I0 + 1.0,				%Index of next element
    {Iv,St1} = exp(V, false, St0),
    {Iv,0,I1,St1};
tc_fields([#efield{v=V}|Fs], I0, St0) ->
    I1 = I0 + 1.0,				%Index of next element
    {Iv,St1} = exp(V, true, St0),
    {Ifs,Fc,I2,St2} = tc_fields(Fs, I1, St1),
    {[?LOAD_LIT(I1),?PUSH] ++ Iv ++ [?PUSH] ++ Ifs,Fc+1,I2,St2};
tc_fields([#kfield{k=K,v=V}|Fs], I0, St0) ->
    {Ik,St1} = exp(K, true, St0),
    {Iv,St2} = exp(V, true, St1),
    {Ifs,Fc,I1,St3} = tc_fields(Fs, I0, St2),
    {Ik ++ [?PUSH] ++ Iv ++ [?PUSH] ++ Ifs,Fc+1,I1,St3};
tc_fields([], I, St) -> {[?LOAD_LIT([])],0,I,St}.