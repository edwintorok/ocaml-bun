module Parse = struct
  let get_stats lines =
    (* did someone say shotgun parsers? *)
    (* separate on : , keep only length 2 lists *)
    let lines = List.map (Astring.String.fields ~empty:false ~is_sep:((=) ':'))
        lines |> List.filter (fun a -> 2 = List.length a) in
    (* drop whitespace *)
    let lines = List.map (List.map Astring.String.trim) lines in
    (* convert 2-length lists to tuples *)
    List.map (function hd::tl::[] -> hd,tl | _ -> assert false) lines

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

end

module Print = struct
  let base64 f =
    Bos.OS.Cmd.run_out @@
    Bos.Cmd.(v "base64" % "-w" % "0" % (Fpath.to_string f)) |>
    Bos.OS.Cmd.to_string

  let output_pasteable str id =
    Printf.sprintf "echo %s | base64 -d > crash_$(date -u +%%s).%d" str id

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
  let print_stats verbose lines =
    let default d = function
      | None -> d
      | Some (_, p) -> p
    in
    match List.length verbose with
    | _ ->
      let execs = Parse.lookup "execs_per_sec" lines |> default "an unknowable number of" in
      let paths = Parse.lookup "paths_found" lines |> default "an unknowable number of" in
      let stability = Parse.lookup "stability" lines |> default "an unknowable amount of" in
      Printf.printf "fuzzing hard at %s executions per second, having already \
                     discovered %s execution paths with %s stability\n%!"
        execs paths stability
end

let rec mon verbose (pids : (int * int) list ref) output : (unit, Rresult.R.msg) result =
  match Bos.OS.Path.matches @@ Fpath.(output / "$(dir)" / "fuzzer_stats") with
  | Error (`Msg e) ->
    (* this is probably just a race -- keep trying *)
    (* (but TODO retry-bound this and terminate so we don't keep trying forever) *)
    Printf.eprintf "%s\n%!" e;
    Unix.sleep 5;
    mon verbose pids output
  | Ok [] ->
    Printf.eprintf "No fuzzer stats files found - waiting on the world to \
                    change\n%!";
    Unix.sleep 1;
    mon verbose pids output
  | Ok _ ->
    (* the caller will know if all children have died. *)
    (* no compelling reason to reimplement afl-whatsup now that we found the
       right env vars to make the afl-fuzz instances do the right thing,
       so let's just run that *)
    let () =
      match Bos.OS.Cmd.run Bos.Cmd.(v "afl-whatsup" % Fpath.to_string output) with
      | Error (`Msg e) -> Printf.eprintf "ignoring error %s\n%!" e
      | Ok () -> ()
    in
    Unix.sleep 60;
    mon verbose pids output
