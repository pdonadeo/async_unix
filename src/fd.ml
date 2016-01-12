open Core.Std
open Import

module File_descr = Unix.File_descr
module Scheduler = Raw_scheduler
module Fd = Raw_fd

include Fd.T

open Fd

let debug                       = debug
let is_closed                   = is_closed
let is_open                     = is_open
let syscall                     = syscall
let syscall_exn                 = syscall_exn
let syscall_result_exn          = syscall_result_exn
let with_file_descr             = with_file_descr
let with_file_descr_exn         = with_file_descr_exn

module Kind = struct
  include Fd.Kind

  let blocking_infer_using_stat file_descr =
    let st = Unix.fstat file_descr in
    match st.st_kind with
    | S_REG | S_DIR | S_BLK | S_LNK -> File
    | S_CHR -> Char
    | S_FIFO -> Fifo
    | S_SOCK ->
      Socket (if Unix.getsockopt file_descr SO_ACCEPTCONN then `Passive else `Active)
  ;;

  let infer_using_stat file_descr =
    In_thread.syscall_exn ~name:"fstat" (fun () -> blocking_infer_using_stat file_descr)
  ;;
end

let to_string t = Sexp.to_string_hum (sexp_of_t t)

let the_one_and_only () = Scheduler.the_one_and_only ~should_lock:true

let create ?avoid_nonblock_if_possible kind file_descr info =
  Scheduler.create_fd ?avoid_nonblock_if_possible (the_one_and_only ()) kind file_descr
    info;
;;

(* If possible, we try not to treat [stdin], [stdout], or [stderr] as nonblocking so that
   one can use Core I/O libraries simultaneously with async without them failing due to
   [Sys_blocked_io]. *)
let create_std_descr file_descr info =
  create (Kind.blocking_infer_using_stat file_descr) file_descr info
    ~avoid_nonblock_if_possible:true
;;

let stdin  =
  Memo.unit (fun () -> create_std_descr Unix.stdin (Info.of_string "<stdin>"))
;;

let stdout =
  Memo.unit (fun () -> create_std_descr Unix.stdout (Info.of_string "<stdout>"))
;;

let stderr =
  Memo.unit (fun () -> create_std_descr Unix.stderr (Info.of_string "<stderr>"))
;;

let clear_nonblock t =
  if t.supports_nonblock then begin
    t.supports_nonblock <- false;
    if t.have_set_nonblock then begin
      t.have_set_nonblock <- false;
      Unix.clear_nonblock t.file_descr;
    end;
  end;
;;

let close ?(should_close_file_descriptor = true) t =
  if debug then Debug.log "Fd.close" t [%sexp_of: t];
  begin match t.state with
  | Close_requested _ | Closed -> ()
  | Open close_started ->
    Ivar.fill close_started ();
    let do_close_syscall () =
      don't_wait_for begin
        let close_finished =
          if not should_close_file_descriptor
          then Deferred.unit
          else
            Monitor.protect
              ~finally:(fun () ->
                In_thread.syscall_exn ~name:"close" (fun () -> Unix.close t.file_descr))
              (fun () ->
                 match t.kind with
                 | Socket `Active ->
                   In_thread.syscall_exn ~name:"shutdown" (fun () ->
                     Unix.shutdown t.file_descr ~mode:SHUTDOWN_ALL)
                 | _ -> return ())
        in
        close_finished
        >>| fun () ->
        Ivar.fill t.close_finished ();
      end
    in
    let scheduler = the_one_and_only () in
    let kernel_scheduler = scheduler.kernel_scheduler in
    set_state t
      (Close_requested (Kernel_scheduler.current_execution_context kernel_scheduler,
                        do_close_syscall));
    (* Notify other users of this fd that it is going to be closed. *)
    Scheduler.request_stop_watching scheduler t `Read  `Closed;
    Scheduler.request_stop_watching scheduler t `Write `Closed;
    (* If there are no syscalls in progress, then start closing the fd. *)
    Scheduler.maybe_start_closing_fd scheduler t;
  end;
  Ivar.read t.close_finished;
;;

let close_finished t = Ivar.read t.close_finished

let close_started t =
  match t.state with
  | Open close_started -> Ivar.read close_started
  | Close_requested _ | Closed -> Deferred.unit
;;

let with_close t ~f = Monitor.protect (fun () -> f t) ~finally:(fun () -> close t)

let with_file_descr_deferred t f =
  match inc_num_active_syscalls t with
  | `Already_closed -> return `Already_closed
  | `Ok ->
    Monitor.try_with (fun () -> f t.file_descr)
    >>| fun result ->
    Scheduler.dec_num_active_syscalls_fd (the_one_and_only ()) t;
    match result with
    | Ok x -> `Ok x
    | Error e -> `Error e
;;

let with_file_descr_deferred_exn t f =
  with_file_descr_deferred t f
  >>| function
  | `Ok x           -> x
  | `Error exn      -> raise exn
  | `Already_closed ->
    failwiths "Fd.with_file_descr_deferred_exn got closed fd" t [%sexp_of: t]
;;

let start_watching t read_or_write watching =
  if debug
  then Debug.log "Fd.start_watching" (t, read_or_write)
         [%sexp_of: t * Read_write.Key.t];
  let r = the_one_and_only () in
  match Scheduler.request_start_watching r t read_or_write watching with
  | `Unsupported | `Already_closed | `Watching as x -> x
  | `Already_watching ->
    failwiths "cannot watch an fd already being watched" (t, r)
      [%sexp_of: t * Scheduler.t]
;;

let stop_watching_upon_interrupt t read_or_write ivar ~interrupt =
  upon
    (choose
       [ choice interrupt (fun () -> `Interrupted);
         choice (Ivar.read ivar) (fun _ -> `Not_interrupted);
       ])
    (function
      | `Not_interrupted -> ()
      | `Interrupted ->
        if Ivar.is_empty ivar
        then Scheduler.request_stop_watching (the_one_and_only ())
               t read_or_write `Interrupted);
;;

let interruptible_ready_to t read_or_write ~interrupt =
  if debug
  then Debug.log "Fd.interruptible_ready_to" (t, read_or_write)
         [%sexp_of: t * Read_write.Key.t];
  let ready = Ivar.create () in
  match start_watching t read_or_write (Watch_once ready) with
  | `Already_closed -> return `Closed
  | `Unsupported -> return `Ready
  | `Watching ->
    stop_watching_upon_interrupt t read_or_write ready ~interrupt;
    Ivar.read ready
;;

let ready_to t read_or_write =
  if debug
  then Debug.log "Fd.ready_to" (t, read_or_write) [%sexp_of: t * Read_write.Key.t];
  let ready = Ivar.create () in
  match start_watching t read_or_write (Watch_once ready) with
  | `Already_closed -> return `Closed
  | `Unsupported -> return `Ready
  | `Watching ->
    Ivar.read ready
    >>| function
    | `Bad_fd | `Closed | `Ready as x -> x
    | `Interrupted -> assert false (* impossible *)
;;

let interruptible_every_ready_to t read_or_write ~interrupt f x =
  if debug
  then Debug.log "Fd.interruptible_every_ready_to" (t, read_or_write)
         [%sexp_of: t * Read_write.Key.t];
  let job = Scheduler.(create_job (t ())) f x in
  let finished = Ivar.create () in
  match start_watching t read_or_write (Watch_repeatedly (job, finished)) with
  | `Already_closed -> return `Closed
  | `Unsupported -> return `Unsupported
  | `Watching ->
    stop_watching_upon_interrupt t read_or_write finished ~interrupt;
    (Ivar.read finished :> [ `Bad_fd | `Closed | `Unsupported | `Interrupted ] Deferred.t)
;;

let every_ready_to t read_or_write f x =
  if debug
  then Debug.log "Fd.every_ready_to" (t, read_or_write)
         [%sexp_of: t * Read_write.Key.t];
  let job = Scheduler.(create_job (t ())) f x in
  let finished = Ivar.create () in
  match start_watching t read_or_write (Watch_repeatedly (job, finished)) with
  | `Already_closed -> return `Closed
  | `Unsupported -> return `Unsupported
  | `Watching ->
    Ivar.read finished
    >>| function
    | `Bad_fd | `Closed as x -> x
    | `Interrupted -> assert false (* impossible *)
;;

let syscall_in_thread t ~name f =
  with_file_descr_deferred t (fun file_descr ->
    In_thread.syscall ~name (fun () -> f file_descr))
  >>| function
  | `Error e ->
    failwiths "Fd.syscall_in_thread problem -- please report this" e [%sexp_of: exn]
  | `Already_closed -> `Already_closed
  | `Ok x ->
    match x with
    | Ok x -> `Ok x
    | Error exn -> `Error exn
;;

let syscall_in_thread_exn t ~name f =
  syscall_in_thread t ~name f
  >>| function
  | `Ok x -> x
  | `Error exn -> raise exn
  | `Already_closed ->
    failwiths "Fd.syscall_in_thread_exn of a closed fd" t [%sexp_of: t]
;;

let of_in_channel ic kind =
  create kind (Unix.descr_of_in_channel ic) (Info.of_string "<of_in_channel>")
;;

let of_out_channel oc kind =
  create kind (Unix.descr_of_out_channel oc) (Info.of_string "<of_out_channel>")
;;

let of_in_channel_auto ic =
  Kind.infer_using_stat (Unix.descr_of_in_channel ic) >>| of_in_channel ic
;;

let of_out_channel_auto oc =
  Kind.infer_using_stat (Unix.descr_of_out_channel oc) >>| of_out_channel oc
;;

let file_descr_exn t =
  if is_closed t
  then failwiths "Fd.file_descr_exn on already closed fd" t [%sexp_of: t]
  else t.file_descr
;;

let to_int_exn t = File_descr.to_int (file_descr_exn t)

let replace t kind info =
  if is_closed t
  then failwiths "Fd.replace got closed fd" (t, kind, the_one_and_only ())
         [%sexp_of: t * Kind.t * Scheduler.t]
  else begin
    t.kind <- kind;
    t.info <- Info.create "replaced" (info, `previously_was t.info)
                [%sexp_of: Info.t * [ `previously_was of Info.t ]];
  end
;;

let%test_module "Fd" =
  (module struct
    let wait_until_cell_is_equal_to cell expected =
      let rec loop tries =
        if tries = 0
        then return false
        else if String.equal !cell expected
        then return true
        else Clock.after (sec 0.1) >>= fun () -> loop (tries - 1)
      in
      loop 100;
    ;;

    let read_into_cell (fd, cell) =
      Unix.set_nonblock fd;
      try
        while true do
          let buf = String.create 1024 in
          let n = Unix.read fd ~buf ~pos:0 ~len:(String.length buf) in
          assert (n > 0);
          cell := !cell ^ String.sub buf ~pos:0 ~len:n
        done
      with Unix.Unix_error ((EAGAIN | EWOULDBLOCK | EINTR), _, _) -> ()
    ;;

    let block_with_timeout f =
      Thread_safe.block_on_async_exn (fun () -> Clock.with_timeout (sec 5.) (f ()))
    ;;

    let%test_unit _ =
      let read = ref "" in
      block_with_timeout (fun () ->
        let fdr, fdw = Unix.pipe () in
        let fdr_async = create Fifo fdr (Info.of_string "<pipe>") in
        let d = every_ready_to fdr_async `Read read_into_cell (fdr, read) in
        assert (String.equal !read "");
        assert (Unix.write fdw ~buf:"foo" ~pos:0 ~len:3 = 3);
        wait_until_cell_is_equal_to read "foo" >>= fun b ->
        assert b;
        assert (Unix.write fdw ~buf:"bar" ~pos:0 ~len:3 = 3);
        wait_until_cell_is_equal_to read "foobar" >>= fun b ->
        assert b;
        close fdr_async >>= fun () -> d)
      |> function
      | `Result `Closed -> assert (String.equal !read "foobar")
      | `Result _ -> assert false
      | `Timeout -> assert false
    ;;

    let%test_unit _ =
      let read = ref "" in
      block_with_timeout (fun () ->
        let fdr, fdw = Unix.pipe () in
        let fdr_async = create Kind.Fifo fdr (Info.of_string "<pipe>") in
        let stop = Ivar.create () in
        let d =
          interruptible_every_ready_to fdr_async `Read read_into_cell (fdr, read)
            ~interrupt:(Ivar.read stop)
        in
        assert (String.equal !read "");
        assert (Unix.write fdw ~buf:"foo" ~pos:0 ~len:3 = 3);
        wait_until_cell_is_equal_to read "foo" >>= fun b ->
        assert b;
        assert (Unix.write fdw ~buf:"bar" ~pos:0 ~len:3 = 3);
        wait_until_cell_is_equal_to read "foobar" >>= fun b ->
        assert b;
        Ivar.fill stop ();
        assert (Unix.write fdw ~buf:"extra" ~pos:0 ~len:5 = 5);
        d)
      |> function
      | `Result `Interrupted -> assert (String.equal !read "foobar")
      | `Result _ -> assert false
      | `Timeout -> assert false
    ;;

    let%test_unit _ =
      let read = ref "" in
      block_with_timeout (fun () ->
        let fdr, fdw = Unix.pipe () in
        let fdr_async = create Fifo fdr (Info.of_string "<pipe>") in
        let stop = Ivar.create () in
        let d =
          interruptible_every_ready_to fdr_async `Read read_into_cell (fdr, read)
            ~interrupt:(Ivar.read stop)
        in
        assert (String.equal !read "");
        assert (Unix.write fdw ~buf:"foo" ~pos:0 ~len:3 = 3);
        wait_until_cell_is_equal_to read "foo" >>= fun b ->
        assert b;
        assert (Unix.write fdw ~buf:"bar" ~pos:0 ~len:3 = 3);
        wait_until_cell_is_equal_to read "foobar" >>= fun b ->
        assert b;
        close fdr_async >>= fun () -> d)
      |> function
      | `Result `Closed -> assert (String.equal !read "foobar")
      | `Result _ -> assert false
      | `Timeout -> assert false
    ;;

    let%test_unit
      "ready_to reports Ready for writer when reader closes after partial read"
      =
      block_with_timeout (fun () ->
        let r, w =
          let r, w = Core.Std.Unix.pipe () in
          create Fifo r (Info.of_string "<reader>"),
          create Fifo w (Info.of_string "<writer>")
        in
        let read =
          ready_to r `Read
          >>= function
          | `Bad_fd -> assert false
          | `Closed -> assert false
          | `Ready  ->
            assert (supports_nonblock r);
            let len = 1 lsl 17 in
            let buf = Bigstring.create len in
            match
              syscall r ~nonblocking:true (fun fd ->
                let res =
                  Unix.Syscall_result.Int.ok_or_unix_error_exn ~syscall_name:"read"
                    (Bigstring.read_assume_fd_is_nonblocking fd buf ~pos:0 ~len)
                in
                assert (res >= 0 && res <= len))
            with
            | `Already_closed -> assert false
            | `Error exn      -> failwiths "read error" exn [%sexp_of: exn]
            | `Ok ()          -> close r
        in
        let len = 1_000_000 in
        let iovec = Unix.IOVec.of_bigstring (Bigstring.create len) in
        let write =
          syscall_in_thread w ~name:"writev" (fun fd ->
            Bigstring.writev fd [| iovec |])
          >>= function
          | `Already_closed -> assert false
          | `Error exn      -> failwiths "write error" exn [%sexp_of: exn]
          | `Ok n           ->
            assert (n >= 0 && n <= len);
            ready_to w `Write
            >>| function
            | `Bad_fd -> assert false
            | `Closed -> assert false
            | `Ready  -> ()
        in
        read
        >>= fun () ->
        write
        >>= fun () ->
        syscall_in_thread w ~name:"writev" (fun fd ->
          Bigstring.writev fd [| iovec |])
        >>| function
        | `Error (Unix.Unix_error (EPIPE, "writev", "")) -> ()
        | `Error exn      -> failwiths "bad write error" exn [%sexp_of: exn]
        | `Ok n           -> failwiths "no write error" n [%sexp_of: int]
        | `Already_closed -> assert false)
      |> function
      | `Result () -> ()
      | `Timeout   -> assert false
    ;;
  end)
