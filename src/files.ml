(* afl-fuzz needs for there to be at least one file in its input directory.
   if the input directory doesn't exist, or it's empty, fix that for the user
   by creating it and making an empty file. *)
let fixup_input input =
  let open Rresult.R in
  Bos.OS.Dir.create input >>= fun _created -> (* Ok anything will do *)
  Bos.OS.Dir.contents input >>= function
  | _::_ -> Ok () (* any file will do! *)
  | [] -> Bos.OS.File.write Fpath.(input / "bun_autogenerated_seed")
            "'rabbit rabbit rabbit'is one variant of a superstition found in Britain and North America that states that a person should say or repeat the word 'rabbit' or 'rabbits', or 'white rabbits', or some combination of these elements, out loud upon waking on the first day of the month, because doing so will ensure good luck for the duration of that month. -- en.wikipedia.org/wiki/Rabbit_rabbit_rabbit"

module Parse = struct
  let get_stats lines =
    (* did someone say shotgun parsers? *)
    List.map (Astring.String.fields ~empty:false ~is_sep:((=) ':')) lines |>
    List.map (List.map Astring.String.trim) |>
    List.fold_left (fun acc -> function | hd::tl::[]-> (hd, tl)::acc
                                        | _ -> acc) [] |> List.rev

  let lookup s l =
    try Some (List.find (fun (a,_) -> Astring.String.equal a s) l) with Not_found -> None

  let lookup_int s l = match lookup s l with
    | None -> None
    | Some (_, i) -> try Some (int_of_string i) with Invalid_argument _ -> None

  let lookup_crashes l = lookup_int "unique_crashes" l
  let lookup_pid l = lookup_int "fuzzer_pid" l

  let get_crash_files ?(id = "$(file)") output_dir =
    let crashes = Fpath.(output_dir / id / "crashes" / "id$(file)" ) in
    Bos.OS.Path.matches crashes

  let get_stats_lines ~id output =
    Bos.OS.File.read_lines Fpath.(output / id / "fuzzer_stats")

  let get_cores cpu =
    let aux gotcpus =
      let process_preamble = "more processes on " in
      let more_processes = Bos.Cmd.(v "grep" % process_preamble) in
      let (>>=) = Rresult.R.bind in
      Bos.OS.Cmd.(run_io more_processes gotcpus |> to_lines) >>= fun l ->
      match List.map (Astring.String.cut ~sep:process_preamble) l
            |> List.find (function | Some _ -> true | None -> false) with
      | None -> Ok 0
      | Some (_, cores) ->
        Logs.debug (fun f -> f "cores line: %s" cores);
        let words = Astring.String.fields cores in
        (* afl-gotcpu sometimes tells us that some CPUs *might* be overcommitted.
           it's usually too conservative; we want to try to use the CPUs that it's
           not sure about. *)
        match Astring.String.compare (List.nth words 1) "to" with
        | 0 -> Ok (List.nth words 2 |> int_of_string)
        | _ -> Ok (List.hd words |> int_of_string)
    in
    let er = Rresult.R.error_msg_to_invalid_arg in
    try
      Bos.OS.Cmd.(run_out ~err:err_run_out (Bos.Cmd.v cpu) |> out_run_in |> er) |>
      aux |> er
    with
    | Not_found | Invalid_argument _ | Failure _ -> 0

end

module Print = struct
  let base64 f =
    Bos.OS.Cmd.run_out @@
    Bos.Cmd.(v "base64" % "-w" % "0" % (Fpath.to_string f)) |>
    Bos.OS.Cmd.to_string

  let output_pasteable str id =
    Printf.sprintf "echo %s | base64 -d > crash_%d.$(date -u +%%s)" str id

  let print_crashes output_dir =
    match Parse.get_crash_files output_dir with
    | Error (`Msg e) ->
      Error (`Msg (Format.asprintf "Failure finding crashes in \
                                    directory %a: %s" Fpath.pp output_dir e))
    | Ok [] ->
      Printf.printf "No crashes found!\n%!"; Ok ()
    | Ok crashes ->
      Printf.printf "Crashes found! Take a look; copy/paste to save for \
                     reproduction:\n%!";
      try
        List.iteri (fun i c ->
            match base64 c with
            | Error _ -> ()
            | Ok base64 ->
              Printf.printf "%s\n%!" (output_pasteable base64 i)
          ) crashes;
        Ok ()
      with
      | Invalid_argument e -> Error (`Msg (Format.asprintf "Failed to base64 a \
                                                            crash file: %s" e))
end
