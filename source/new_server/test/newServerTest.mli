(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Newserver

module Client : sig
  type t

  val current_server_state : t -> ServerState.t

  val send_request : t -> Request.t -> string Lwt.t

  val assert_response : request:Request.t -> expected:Response.t -> t -> unit Lwt.t

  val subscribe
    :  subscription:Subscription.Request.t ->
    expected_response:Response.t ->
    t ->
    unit Lwt.t

  val assert_subscription_response : expected:Subscription.Response.t -> t -> unit Lwt.t

  val close : t -> unit Lwt.t
end

module ScratchProject : sig
  type t = {
    context: OUnit2.test_ctxt;
    server_configuration: ServerConfiguration.t;
    watchman: Watchman.Raw.t option;
    build_system: BuildSystem.t;
  }

  val setup
    :  context:OUnit2.test_ctxt ->
    ?external_sources:(string * string) list ->
    ?include_typeshed_stubs:bool ->
    ?include_helper_builtins:bool ->
    ?watchman:Watchman.Raw.t ->
    ?build_system:BuildSystem.t ->
    (* A list of test sources specified in the form of (relative_path, content) *)
    (string * string) list ->
    t

  val test_server_with
    :  ?expected_exit_status:Start.ExitStatus.t ->
    ?on_server_socket_ready:(Pyre.Path.t -> unit Lwt.t) ->
    f:(Client.t -> unit Lwt.t) ->
    t ->
    unit Lwt.t
end
