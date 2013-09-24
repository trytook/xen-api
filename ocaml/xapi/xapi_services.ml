(*
 * Copyright (C) 2011 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
(** Advertise services
 *)

module D=Debug.Make(struct let name="xapi" end)
open D

open Fun
open Stringext
open Pervasiveext
open Threadext
open Constants

type driver_list = Storage_interface.query_result list with rpc

let list_sm_drivers ~__context =
	let all = List.map (Smint.query_result_of_sr_driver_info ++ Sm.info_of_driver) (Sm.supported_drivers ()) in
	rpc_of_driver_list all

let respond req rpc s =
	let txt = Jsonrpc.to_string rpc in
	Http_svr.headers s (Http.http_200_ok ~version:"1.0" ~keep_alive:false ());
	req.Http.Request.close <- true;
	Unixext.really_write s txt 0 (String.length txt)

let list_drivers req s = respond req (System_domains.rpc_of_services (System_domains.list_services ())) s

let fix_cookie cookie =
  let str_cookie = String.concat "; " (List.map (fun (k,v) -> Printf.sprintf "%s=%s" k v) cookie) in

  let cookie_re = Re_str.regexp "[;,][ \t]*" in
  let equals_re = Re_str.regexp_string "=" in

  let comps = Re_str.split_delim cookie_re str_cookie in
          (* We don't handle $Path, $Domain, $Port, $Version (or $anything
             $else) *)
  let cookies = List.filter (fun s -> s.[0] != '$') comps in
  let split_pair nvp =
    match Re_str.split_delim equals_re nvp with
    | [] -> ("","")
    | n :: [] -> (n, "")
    | n :: v :: _ -> (n, v)
  in 
  (List.map split_pair cookies)

(* Transmits [req] and [s] to the service listening on [path] *)
let hand_over_connection req s path =
	try
		debug "hand_over_connection %s %s to %s" (Http.string_of_method_t req.Http.Request.m) req.Http.Request.uri path;
		let control_fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
		let req = Http.Request.({ req with cookie=fix_cookie req.cookie}) in
		finally
			(fun () ->
				Unix.connect control_fd (Unix.ADDR_UNIX path);
				let msg = req |> Http.Request.rpc_of_t |> Jsonrpc.to_string in
				let len = String.length msg in
				let written = Unixext.send_fd control_fd msg 0 len [] s in
				if written <> len then begin
					error "Failed to transfer fd to %s" path;
					Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
					req.Http.Request.close <- true;
					None
				end else begin
					let response = Http_client.response_of_fd control_fd in
					match response with
					| Some res -> res.Http.Response.task
					| None -> None
				end
			)
			(fun () -> Unix.close control_fd)
	with e ->
		error "Failed to transfer fd to %s: %s" path (Printexc.to_string e);
		Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
		req.Http.Request.close <- true;
		None

let http_proxy_to req from addr =
	let s = Unix.socket (Unix.domain_of_sockaddr addr) Unix.SOCK_STREAM 0 in
	finally
		(fun () ->
			let () =
				try
					Unix.connect s addr;
				with e ->
					error "Failed to proxy HTTP request to: %s" (match addr with
						| Unix.ADDR_UNIX path -> "UNIX:" ^ path
						| Unix.ADDR_INET(ip, port) -> "IP:" ^ (Unix.string_of_inet_addr ip) ^ ":" ^ (string_of_int port)
					);
					Http_svr.headers from (Http.http_404_missing ~version:"1.0" ());
					raise e in
			Http_proxy.one req from s)
		(fun () -> Unix.close s)

let http_proxy_to_plugin req from name =
	let path = Filename.concat Fhs.vardir (Printf.sprintf "plugin/%s" name) in
	if not (Sys.file_exists path) then begin
		req.Http.Request.close <- true;
		error "There is no Unix domain socket %s for plugin %s" path name;
		Http_svr.headers from (Http.http_404_missing ~version:"1.0" ())
	end else
		http_proxy_to req from (Unix.ADDR_UNIX path)

let post_handler (req: Http.Request.t) s _ =
	Xapi_http.with_context ~dummy:true "Querying services" req s
		(fun __context ->
			match String.split '/' req.Http.Request.uri with
				| "" :: services :: "xenops" :: _ when services = _services ->
					let queue_name =
						if List.mem_assoc "queue" req.Http.Request.cookie
						then List.assoc "queue" req.Http.Request.cookie
						else "org.xen.xcp.xenops.classic" in (* upgrade *)
					(* over the network we still use XMLRPC *)
					let request = Http_svr.read_body req (Buf_io.of_fd s) in
					let request = Jsonrpc.string_of_call (Xmlrpc.call_of_string request) in
					let response = Xcp_client.switch_rpc queue_name (fun x -> x) (fun x -> x) request in
					let response = Xmlrpc.string_of_response (Jsonrpc.response_of_string response) in
					Http_svr.response_str req ~hdrs:[] s response
				| "" :: services :: "plugin" :: name :: _ when services = _services ->
					http_proxy_to_plugin req s name
				| [ ""; services; "SM" ] when services = _services ->
					Storage_impl.Local_domain_socket.xmlrpc_handler Storage_mux.Server.process req (Buf_io.of_fd s) ()
				| _ ->
					Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
					req.Http.Request.close <- true
		)


let rpc ~srcstr ~dststr call =
	let url = Http.Url.(File { path = Filename.concat Fhs.vardir "storage" }, { uri = "/"; query_params = [] }) in
	let open Xmlrpc_client in
	XMLRPC_protocol.rpc ~transport:(transport_of_url url) ~srcstr ~dststr
		~http:(xmlrpc ~version:"1.0" ?auth:(Http.Url.auth_of url) ~query:(Http.Url.get_query_params url) (Http.Url.get_uri url)) call

module Local = Storage_interface.Client(struct let rpc = rpc ~srcstr:"xapi" ~dststr:"smapiv2" end)

let put_handler (req: Http.Request.t) s _ =
	Xapi_http.with_context ~dummy:true "Querying services" req s
		(fun __context ->
			match String.split '/' req.Http.Request.uri with
				| "" :: services :: "xenops" :: "memory" :: [ id ] when services = _services ->
					req.Http.Request.close <- true;
					let req = Http.Request.({ req with cookie=fix_cookie req.cookie}) in
					info "XXX cookie = [ %s ]" (String.concat "; " (List.map (fun (k, v) -> k ^ ", " ^ v) req.Http.Request.cookie));
					let open Xapi_xenops_queue in
					let dbg = Context.string_of_task __context in
					if not(List.mem_assoc "instance_id" req.Http.Request.cookie) then begin
						error "remote did not include an instance_id cookie.";
						Http_svr.response_str req ~hdrs:[] s "instance_id cookie is missing.";
						failwith "remote did not include an instance_id cookie"
					end;
					let instance_id = List.assoc "instance_id" req.Http.Request.cookie in
					info "instance_id ok";
					if not(List.mem_assoc "memory_limit" req.Http.Request.cookie) then begin
						error "remote did not include a memory_limit cookie.";
						Http_svr.response_str req ~hdrs:[] s "memory_limit cookie is missing.";
						failwith "remote did not include a memory_limit cookie"
					end;
					let memory_limit = Int64.of_string (List.assoc "memory_limit" req.Http.Request.cookie) in
					info "memory_limit ok";
					let self = Xapi_xenops.vm_of_id ~__context id in
					info "got self";
					let queue_name = queue_of_vm ~__context ~self in
					info "got queue";
					info "importing VM %s memory image via %s" id queue_name;
					let module Client = (val (make_client queue_name) : XENOPS) in
					let task = Client.VM.migrate_receive_memory dbg id memory_limit instance_id (Xcp_channel.t_of_file_descr s) in
					info "waiting for migrate_receive_memory to complete";
					Opt.iter (fun t -> t |> Xenops_client.wait_for_task dbg |> ignore) task;
					info "handler complete"
				| "" :: services :: "plugin" :: name :: _ when services = _services ->
					http_proxy_to_plugin req s name
				| [ ""; services; "SM"; "data"; sr; vdi ] when services = _services ->
					let vdi, _ = Storage_access.find_vdi ~__context sr vdi in
					Import_raw_vdi.import vdi req s ()
				| [ ""; services; "SM"; "nbd"; sr; vdi; dp ] when services = _services ->
					Storage_migrate.nbd_handler req s sr vdi dp
				| _ ->
					Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
					req.Http.Request.close <- true
		)

let get_handler (req: Http.Request.t) s _ =
	Xapi_http.with_context ~dummy:true "Querying services" req s
		(fun __context ->
			debug "uri = %s" req.Http.Request.uri;
			match String.split '/' req.Http.Request.uri with
				| "" :: services :: "xenops" :: _ when services = _services ->
					ignore (hand_over_connection req s (Filename.concat Fhs.vardir "xenopsd.forwarded"))
				| "" :: services :: "plugin" :: name :: _ when services = _services ->
					http_proxy_to_plugin req s name
				| "" :: services :: "driver" :: [] when services = _services ->
					list_drivers req s
				| [ ""; services; "SM"; driver ] when services = _services ->
					begin
						try
							respond req (Storage_interface.rpc_of_query_result (Smint.query_result_of_sr_driver_info (Sm.info_of_driver driver))) s
						with _ ->
							Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
							req.Http.Request.close <- true
					end
				| [ ""; services; "SM" ] when services = _services ->
					let rpc = list_sm_drivers ~__context in
					respond req rpc s
(* XXX
				| [ ""; services ] when services = _services ->
					let q = {
						Storage_interface.driver = "mux";
						name = "storage multiplexor";
						description = "forwards calls to other plugins";
						vendor = "XCP";
						copyright = "see the source code";
						version = "2.0";
						required_api_version = "2.0";
						features = List.map (fun x -> (path [_services; x])) [ _SM ];
						configuration = []
					} in
					respond req (Storage_interface.rpc_of_query_result q) s
*)
				| _ ->
					Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
					req.Http.Request.close <- true
		)

	
