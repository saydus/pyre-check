(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module ServerEvent : sig
  type t =
    | SocketCreated of Pyre.Path.t
    | ServerInitialized
    | Exception of string
  [@@deriving sexp, compare, hash]

  val serialize : t -> string

  val write : output_channel:Lwt_io.output_channel -> t -> unit Lwt.t
end

module ExitStatus : sig
  type t =
    | Ok
    | Error
  [@@deriving sexp, compare, hash]

  val exit_code : t -> int
end

(* Start the server from a given configuration. Then invoke `on_started` if the server starts and
   its state fully initialized. *)
(* If `on_server_socket_ready` is provided, it will be invoked right after the server socket gets
   established and just before the server state initialization takes place. The argument passed to
   `on_server_socket_ready` is the path to the socket file. *)
(* If the server fails to start, or if an exception is raised from `on_started`, invoke
   `on_exception raised_exception`. *)
(* The server will be automatically shut down after the promise returned by either `on_started` or
   `on_exception` fulfills. *)
val start_server
  :  ?watchman:Watchman.Raw.t ->
  ?build_system:BuildSystem.t ->
  ?on_server_socket_ready:(Pyre.Path.t -> unit Lwt.t) ->
  on_started:(ServerState.t ref -> ExitStatus.t Lwt.t) ->
  on_exception:(exn -> ExitStatus.t Lwt.t) ->
  ServerConfiguration.t ->
  ExitStatus.t Lwt.t

(* Start the server and blocks forever until exceptional events occur. Returns immediately when the
   server fails to start. *)
(* If `event_channel` is provided, the server will use it to communicate additional status info of
   the server back. As soon as one of the event represented by `ServerEvent.t` happens, it writes a
   text message to `status_channel` if the channel is still open. *)
val start_server_and_wait
  :  ?event_channel:Lwt_io.output_channel ->
  ServerConfiguration.t ->
  ExitStatus.t Lwt.t
