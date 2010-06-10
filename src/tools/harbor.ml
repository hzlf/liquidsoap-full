(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2010 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

open Unix
open Dtools
open Http_source

let conf_harbor =
  Conf.void ~p:(Configure.conf#plug "harbor")
    "HTTP stream receiver (minimal icecast/shoutcast clone)."
let conf_harbor_port =
  Conf.int ~p:(conf_harbor#plug "port") ~d:8005
    "Port on which the HTTP stream receiver should listen."
let conf_harbor_bind_addr =
  Conf.string ~p:(conf_harbor#plug "bind_addr") ~d:"0.0.0.0"
    "IP address on which the HTTP stream receiver should listen."
let conf_harbor_user =
  Conf.string ~p:(conf_harbor#plug "username") ~d:"source"
    "Default username for source connection."
let conf_harbor_pass =
  Conf.string ~p:(conf_harbor#plug "password") ~d:"hackme"
    "Default password for source connection."
let conf_icy =
  Conf.bool ~p:(conf_harbor#plug "icy") ~d:false
    "Enable the ICY (shout) protocol."
let conf_timeout =
  Conf.float ~p:(conf_harbor#plug "timeout") ~d:30.
    "Timeout for source connections."
let conf_pass_verbose =
  Conf.bool ~p:(conf_harbor_pass#plug "verbose") ~d:false
    "Display passwords, for debugging."
let conf_revdns =
  Conf.bool ~p:(conf_harbor#plug "reverse_dns") ~d:true
    "Perform reverse DNS lookup to get the client's hostname from its IP."
let conf_icy_metadata = 
  Conf.list ~p:(conf_icy#plug "metadata_formats") 
  ~d:["audio/mpeg"; "audio/aacp"; "audio/aac"; "audio/x-aac"]
  "Content-type (mime) of formats which allow shout metadata update."

let opened_ports = ref []

let log = Log.make ["harbor"]

exception Internal
exception Registered

(* Define what we need as a source *)
class virtual source ~kind =
object(self)
  inherit Source.source kind

  method virtual relay : (string*string) list -> Unix.file_descr -> unit
  method virtual insert_metadata : (string, string) Hashtbl.t -> unit
  method virtual login : (string option)*(string -> string -> bool)
  method virtual is_taken : bool
  method virtual register_decoder : string -> unit
  method virtual get_mime_type : string option

end

let sources : (string*int,source) Hashtbl.t = Hashtbl.create 1

let find_source mountpoint port =
  Hashtbl.find sources (mountpoint,port)

(** {1 Handling of a client} *)

exception Exit
exception Too_many_sources
exception Not_authenticated
exception Xaudiocast_auth
(* Answer to close communication *)
exception Answer of (unit->unit)
exception Not_supported
exception Unknown_codec
exception Mount_taken

type request_type =
  | Source
  | Get
  | Shout
  | Invalid of string (* Used for icy *)
  | Unhandled

type protocol =
  | Http_10
  | Http_11
  | Icy
  | Unknown of string (* Used for xaudiocast *)

let http_error_page code status msg =
  ( "HTTP/1.0 " ^ (string_of_int code) ^ " " ^ status ^ "\r\n\
     Content-Type: text/html\r\n\r\n\
     <?xml version=\"1.0\" encoding=\"utf-8\"?>\n\
     <!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \
     \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">\n\
     <html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"en\">\
     <head><title>Liquidsoap source harbor</title></head>\
     <body><p>" ^ msg ^ "</p></body></html>\n" )

let parse_icy_request_line ~port r =
      (try
        let s = find_source "/" (port-1) in
        let user,auth_f = s#login in
        let user = 
          match user with
            | Some v -> v
            | None -> conf_harbor_user#get
        in
        if auth_f user r then
          Shout
        else
          Invalid("invalid password")
      with
        | _ -> Invalid("no / mountpoint")),
      "/",
      Icy

let parse_http_request_line r =
  let data = Str.split (Str.regexp "[ \t]+") r in
    (
      (match (String.uppercase (List.nth data 0)) with
        | "SOURCE" -> Source
        | "GET" -> Get
        | _ -> Unhandled),
      (List.nth data 1),
      (match (String.uppercase (List.nth data 2)) with
        | "HTTP/1.0" -> Http_10
        | "HTTP/1.1" -> Http_11
        | s -> Unknown(s))
    )

let write_answer ?(keep=false) c a =
  ignore (Unix.write c a 0 (String.length a)) ;
  if not keep then
    try
      Unix.shutdown c Unix.SHUTDOWN_ALL ;
      Unix.close c
    with
      | _ -> ()

let parse_headers headers =
  let split_header h l =
    try
      let rex = Pcre.regexp "([^:\\r\\n]+):\\s*([^\\r\\n]+)" in
      let sub = Pcre.exec ~rex h in
      (String.uppercase (Pcre.get_substring sub 1),
       Pcre.get_substring sub 2) :: l
    with
      | Not_found -> l
  in
  let headers = List.fold_right split_header headers [] in
  let display_headers = 
    List.filter (fun (x,_) -> conf_pass_verbose#get || x <> "AUTHORIZATION") headers
  in
  List.iter (fun (h, v) -> log#f 4 "Header: %s, value: %s." h v) display_headers ;
  headers

let auth_check ~login c uri headers =
    (* 401 error model *)
    let answer s =
      write_answer c
        (http_error_page 401
           "Unauthorized\r\n\
            WWW-Authenticate: Basic realm=\"Liquidsoap harbor\""
           s)
    in
    let valid_user,auth_f = login in
    let valid_user = 
      match valid_user with
        | None -> conf_harbor_user#get
        | Some s -> s 
    in
    try
      (* Authentication *)
      let auth = List.assoc "AUTHORIZATION" headers in
      let data = Str.split (Str.regexp "[ \t]+") auth in
        if List.nth data 0 <> "Basic" then raise Not_supported ;
        let auth_data =
          Str.split (Str.regexp ":") (Utils.decode64 (List.nth data 1))
        in
        let user,pass = List.nth auth_data 0, List.nth auth_data 1 in
          if conf_pass_verbose#get then
            log#f 4 "Requested username: %s, password: %s." user pass ;
          if not (auth_f user pass) then
            raise Not_authenticated ;
          (* OK *)
          log#f 4 "Client logged in."
    with
      | Not_found ->
          if auth_f valid_user uri then
            ( log#f 4 "xaudiocast login" ;
            raise Xaudiocast_auth )
          else
            raise (Answer(fun () ->
                ( log#f 3 "Returned 401: no authentification given." ;
                  answer "No login / password supplied." ) ) )
      | Not_authenticated ->
            raise (Answer(fun () ->
             ( log#f 3 "Returned 401: wrong auth." ;
               answer "Wrong Authentification data") ) )
      | Not_supported ->
            raise (Answer(fun () ->
             ( log#f 3 "Returned 401: bad authentification." ;
               answer "No login / password supplied.") ) )

let handle_source_request ~port ~icy hprotocol c uri headers =
  try
    (* ICY request are on port+1 *)
    let source_port = if icy then port-1 else port in
    let s = find_source uri source_port in
    let icy,uri =
      try
        (* ICY auth check was done before.. *)
        if not icy then
          auth_check ~login:s#login c uri headers ;
        icy,uri
      with
        | Xaudiocast_auth ->
            begin match hprotocol with
                    | Unknown(s) ->
                        write_answer ~keep:true c "OK\r\n\r\n" ;
                        true,s
                    | _ ->
                       failwith
                         "Incorrect xaudiocast source request."
            end
        | e -> raise e
    in
    let sproto = match icy with
                  | true -> "ICY"
                  | false -> "SOURCE"
    in
    log#f 3 "%s request on %s." sproto uri ;
    let stype =
      try
        List.assoc "CONTENT-TYPE" headers
      with
        | Not_found when icy -> "audio/mpeg"
        | Not_found -> raise Unknown_codec
    in
    match s#is_taken with
      | true -> raise Mount_taken
      | _ ->
          s#register_decoder stype ;
          log#f 3 "Adding source on mountpoint %S with type %S." uri stype ;
          if not icy then write_answer ~keep:true c "HTTP/1.0 200 OK\r\n\r\n" ;
          s#relay headers c
  with
    | Mount_taken ->
        log#f 3 "Returned 403: Mount taken" ;
        write_answer c
          (http_error_page 403
             "Unauthorized\r\n\
              WWW-Authenticate: Basic realm=\"Liquidsoap harbor\""
             "Mountpoint in use") ;
        failwith "Mountpoint in use"
    | Not_found ->
        log#f 3 "Returned 404 for '%s'." uri ;
        write_answer c
          (http_error_page 404 "Not found"
             "This mountpoint isn't available.") ;
        failwith "no such mountpoint"
    | Unknown_codec ->
        log#f 3 "Returned 501: unknown audio codec" ;
        write_answer c
          (http_error_page 501 "Not Implemented"
             "This stream's format is not recognized.") ;
        failwith "bad codec"
    | Answer s ->
          s () ;
          failwith "wrong source authentification"
    | e ->
        log#f 3 "Returned 500 for '%s'." uri ;
        write_answer c
          (http_error_page 500 "Internal Server Error"
             "The server could not handle your request.") ;
        failwith (Printexc.to_string e)

let handle_get_request ~port c uri headers =
  let default =
    "HTTP/1.0 200 OK\r\n\
     Content-Type: text/html\r\n\r\n\
     <?xml version=\"1.0\" encoding=\"utf-8\"?>\n\
     <!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \
     \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">\n\
     <html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"en\">\
     <head><title>Liquidsoap source harbor</title></head>\
     <body><p>Liquidsoap's harbor main page</p></body></html>\n"
  in
  let ans_404 = fun () ->
    log#f 3 "Returned 404 for '%s'." uri ;
    write_answer c (http_error_page 404 "Not found"
    "This page isn't available.")
  in
  let ans_500 = fun () ->
    log#f 3 "Returned 500 for '%s'." uri ;
    write_answer c (http_error_page 500 "Internal Server Error"
    "There was an error processing your request.")
  in
  let admin args =
    match
      try Hashtbl.find args "mode"
      with Not_found -> raise (Answer(ans_404))
    with
      | "updinfo" ->
          let mount =
            try
              Hashtbl.find args "mount"
            with Not_found -> "/"
          in
            log#f 3 "Request to update metadata for mount %s on port %i" mount port;
            let s = find_source mount port in
              begin try
                auth_check ~login:s#login c uri headers
              with
                | e ->
                    try
                      let (user,auth_f) = s#login in
                     let user =
                       match user with
                          | Some s -> s
                          | None -> conf_harbor_user#get
                      in
                     let pass = Hashtbl.find args "pass"
                      in
                      let ans () =
                        log#f 3 "Returned 401 for '%s': wrong auth." uri ;
                        write_answer c
                          (http_error_page 401 "Authentification Failed"
                             "Wrong Authentification data")
                      in
                        if not (auth_f user pass) then
                          raise (Answer ans)
                    with
                      | Not_found -> raise e
              end ;
              let ans () =
                log#f 3 "Returned 405 for '%s': Source format does not support \
                         ICY metadata update" uri ;
                write_answer c
                  (http_error_page 405 "Method Not Allowed"
                    "Method Not Allowed: Source is not mp3")
              in
              if not (List.mem (Utils.get_some s#get_mime_type) 
                               conf_icy_metadata#get) 
              then
                raise (Answer ans) ;
              let ans =
                Printf.sprintf
                  "HTTP/1.0 200 OK\r\n\r\n\
                    Updated metadatas for mount %s\n"
                    mount
              in
              Hashtbl.remove args "mount";
              Hashtbl.remove args "mode";
              s#insert_metadata args ;
              raise (Answer (fun () -> write_answer c ans))
     | _ -> raise (Answer ans_500)
  in
  let rex = Pcre.regexp "^(.+)\\?(.+)$" in
  let base_uri,args =
  try
    let sub = Pcre.exec ~rex:rex uri in
    Pcre.get_substring sub 1,
    Pcre.get_substring sub 2
  with
    | Not_found -> uri,""
  in
  log#f 3 "GET request on %s." base_uri ;
  let args = Http.args_split args in
  (* decoder args *)
  let args = 
    let ret = Hashtbl.create (Hashtbl.length args) in
    let g = Http.url_decode in
    let f x y = Hashtbl.add ret (g x) (g y) in 
    Hashtbl.iter f args ;
    ret
  in
  (* Filter out password *)
  let log_args = 
    if conf_pass_verbose#get then
      args
    else
      let log_args = Hashtbl.copy args in
      Hashtbl.remove log_args "pass" ;
      log_args
  in 
  Hashtbl.iter (fun h v -> log#f 4 "GET Arg: %s, value: %s." h v) log_args ;
  try
     match base_uri with
       | "/" -> write_answer c default
       | "/admin/metadata" | "/admin.cgi"
             -> admin args
       | _ -> raise (Answer(ans_404))
  with
    | Answer(s) ->  s ()
    | e -> ans_500 () ; failwith (Printexc.to_string e)

let priority = Tutils.Non_blocking

let handle_client ~port ~icy socket =
  let on_error _ =
    log#f 3 "Client left." ;
    try
      Unix.shutdown socket Unix.SHUTDOWN_ALL ;
      Unix.close socket
    with
      | _ -> ()
  in
  (* Read and process lines *)
  let marker =
    match icy with
      | true -> Duppy.Io.Split "[\r]?\n"
      | false -> Duppy.Io.Split "[\r]?\n[\r]?\n"
  in
  let recursive = false in
  let parse = match icy with
                 | true -> parse_icy_request_line ~port
                 | false -> parse_http_request_line
  in
  let process l =
    try
      let grab l = 
        let l =
         match List.rev l with
           | []
           | _ :: [] -> (* Should not happen *)
               raise (Failure "Invalid input data")
           | e :: l -> List.rev l
        in
        match l with
          | s :: _ -> s
          | _ -> failwith "could not parse source data."
      in
      let s = grab l in
      let lines = Str.split (Str.regexp "\n") s in
      let (hmethod, huri, hprotocol) = parse (List.nth lines 0) in
        match hmethod with
          | Source when not icy ->
              let headers = parse_headers (List.tl lines) in
              handle_source_request ~port ~icy hprotocol socket huri headers
          | Get when not icy ->
              let headers = parse_headers (List.tl lines) in
              handle_get_request ~port socket huri headers
          | Shout when icy ->
              write_answer ~keep:true socket "OK2\r\nicy-caps:11\r\n\r\n" ;
              (* Now parsing headers *)
              let marker = Duppy.Io.Split "[\r]?\n[\r]?\n" in
              let process l = 
                try
                 let s = grab l in
                 let lines = Str.split (Str.regexp "\n") s in
                 let headers = parse_headers (List.tl lines) in
                 handle_source_request ~port ~icy:true hprotocol socket huri headers
                with
                  | Failure s ->
                      log#f 3 "Failed: %s" s;
                      try
                       Unix.shutdown socket Unix.SHUTDOWN_ALL ;
                       Unix.close socket
                      with
                        | _ -> ()
              in
              Duppy.Io.read ~priority ~recursive ~on_error
                            Tutils.scheduler socket marker process
          | Invalid s ->
              let er = if icy then "ICY " else "" in
              write_answer socket (Printf.sprintf "%s\r\n" s) ;
              failwith (Printf.sprintf "Invalid %srequest: %s" er s)
          | _ ->
            log#f 3 "Returned 501." ;
            write_answer socket
              (http_error_page 501 "Not Implemented"
                 "The server did not understand your request.") ;
            failwith "cannot handle this, exiting"
    with
      | Failure s -> 
          log#f 3 "Failed: %s" s;
          try
            Unix.shutdown socket Unix.SHUTDOWN_ALL ;
            Unix.close socket
          with
            | _ -> ()
    in
      Duppy.Io.read ~priority ~recursive ~on_error
        Tutils.scheduler socket marker process

(* {1 The server} *)

let shutdown = ref false
let stop () = shutdown := true

(* Open a port and listen to it. *)
let open_port port = 
  let rec incoming ~port ~icy sock _ =
    begin
      try
        if !shutdown then failwith "shutting down" ;
        let (socket,caller) = accept sock in
        let ip =
          let a =
            match caller with
              | ADDR_INET (a,_) -> a
              | _ -> assert false
          in
            try
              if not conf_revdns#get then raise Not_found ;
              (gethostbyaddr a).h_name
            with
              | Not_found -> string_of_inet_addr a
        in
        (* Add timeout *)
        Unix.setsockopt_float socket Unix.SO_RCVTIMEO conf_timeout#get ;
        Unix.setsockopt_float socket Unix.SO_SNDTIMEO conf_timeout#get ;
        handle_client ~port ~icy socket ;
        log#f 3 "New client on port %i: %s" port ip
      with e -> log#f 2 "Failed to accept new client: %s" (Printexc.to_string e)
    end ;
    if !shutdown then begin
      (try Unix.close sock with _ -> ()) ;
      []
    end else
      [{ Duppy.Task.
         priority = priority ;
         events = [`Read sock] ;
         handler = (incoming ~port ~icy sock) }]
  in
  let open_socket port =
    let bind_addr = conf_harbor_bind_addr#get in
    let bind_addr_inet =
      inet_addr_of_string bind_addr
    in
    let bind_addr = ADDR_INET(bind_addr_inet, port) in
    let max_conn = Hashtbl.length sources in
    let sock = socket PF_INET SOCK_STREAM 0 in
    setsockopt sock SO_REUSEADDR true ;
    (* Set TCP_NODELAY on the socket *)
    Liq_sockets.set_tcp_nodelay sock true ;
    (* Add timeout *)
    Unix.setsockopt_float sock Unix.SO_RCVTIMEO conf_timeout#get ;
    Unix.setsockopt_float sock Unix.SO_SNDTIMEO conf_timeout#get ;
    begin try bind sock bind_addr with
      | Unix.Unix_error(Unix.EADDRINUSE, "bind", "") ->
          failwith (Printf.sprintf "port %d already taken" port)
    end ;
    listen sock max_conn ;
    sock
  in
  let sock = open_socket port in
  opened_ports := port :: !opened_ports ;
  Duppy.Task.add Tutils.scheduler
    { Duppy.Task.
        priority = priority ;
        events   = [`Read sock] ;
        handler  = incoming ~port ~icy:false sock } ;
  (* Now do the same for ICY if enabled *)
  if conf_icy#get then
    (* Open port+1 *)
    let port = port+1 in
    let sock = open_socket port in
    Duppy.Task.add Tutils.scheduler
      { Duppy.Task.
          priority = priority ;
          events   = [`Read sock] ;
          handler  = incoming ~port ~icy:true sock }

(* Add sources... *)
let add_source ?port mountpoint source =
  let port =
    match port with
      | Some x -> 
          if not (List.mem x !opened_ports) then
          open_port x ;
          x
      | None   -> conf_harbor_port#get
  in
  if Hashtbl.mem sources (mountpoint,port) then
    raise Registered ;
  log#f 3 "Adding mountpoint '%s' on port %i"
     mountpoint port;
  Hashtbl.add sources (mountpoint,port) source

let start_harbor () = 
  (* Open main port *)
  open_port conf_harbor_port#get

let start () =
  if Sys.os_type <> "Win32" then
    Sys.set_signal Sys.sigpipe Sys.Signal_ignore ;
  if Hashtbl.length sources > 0 then begin
    Tutils.need_non_blocking_queue () ;
    start_harbor ()
  end

let () = ignore (Dtools.Init.at_start start)
