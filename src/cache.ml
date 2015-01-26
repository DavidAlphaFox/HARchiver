open Core.Std
open Lwt

type ('a, 'b) entry = {
	element: 'a option;
	t_expire: unit Lwt.t;
	mutable waiting: ('a, 'b) Result.t Lwt.u list;
}

type ('a, 'b) t = (string, ('a, 'b) entry) Hashtbl.t


let create () = Hashtbl.create ~hashable:String.hashable ()

(* Creates a thread that expires after `exp` and invalidates the element if no one is waiting for it *)
let make_expire c key exp =
	Lwt_unix.sleep exp
	>>= fun () ->
		match Hashtbl.find c key with
		| None -> return ()
		| Some item ->
			match item.waiting with
			| [] -> return (Hashtbl.remove c key)
			| _ -> return ()

(* An element was found, this updates the entry *)
let put c key data exp =
	let item = {
		element = Some data;
		t_expire = (make_expire c key exp);
		waiting = [];
	}
	in
	Hashtbl.replace c ~key ~data:item

(* Returns the cached element if it exists.
Otherwise, either goes fetch it itself if no other thread is
currently doing it, or wait for the result of that other thread and return it.
Call `get` inside Lwt.pick with a timeout if there's a chance the thunk might never return. *)
let get c ~key ~exp ~thunk =
	match Hashtbl.find c key with
	| Some found -> (
		match found.element with
		| Some el ->
			(* There's something *)
			Lwt.return (Ok el)
		| None ->
			(* Currently being fetched *)
			let (thread, wakener) = Lwt.wait () in
			let () = found.waiting <- (wakener::found.waiting) in
			thread)
	| None ->
		(* Go get it yourself *)
		let new_cached = {
			element=None;
			t_expire=(make_expire c key exp);
			waiting=[];
		}
		in
		let _ = Hashtbl.add c ~key ~data:new_cached in
		thunk ()
		>>= fun res ->
			(* There's a response, remove the expiration thread and wake every thread up *)
			let () = Lwt.cancel new_cached.t_expire in
			let () = List.iter ~f:(fun w -> Lwt.wakeup w res) new_cached.waiting in
			let () = match res with
			| Ok v ->
				put c key v exp
			| Error _ ->
				Hashtbl.remove c key
			in
			return res