open Import

module Pos = struct
  open OpamParserTypes.FullPos

  let default = { filename = "None"; start = (0, 0); stop = (0, 0) }
  let from_value { pos; _ } = pos
  let with_default_pos pelem = { pos = default; pelem }

  let errorf ~pos fmt =
    let startl, startc = pos.start in
    let stopl, stopc = pos.stop in
    Format.ksprintf
      (fun msg -> Error (`Msg msg))
      ("Error in opam-monorepo lockfile %s, [%d:%d]-[%d:%d]: " ^^ fmt)
      pos.filename startl startc stopl stopc
end

let value_errorf ~value fmt =
  let pos = Pos.from_value value in
  Pos.errorf ~pos fmt

module Extra_field = struct
  include Opam.Extra_field

  let get ?file t opam =
    match get t opam with
    | Some result -> result
    | None ->
        let file_suffix_opt = Option.map ~f:(Printf.sprintf " %s") file in
        let file_suffix = Option.value ~default:"" file_suffix_opt in
        Error
          (`Msg
            (Printf.sprintf "Missing %s field in opam-monorepo lockfile%s"
               (name t) file_suffix))
end

module Version = struct
  type t = int * int

  let current = (0, 2)
  let pp fmt (major, minor) = Format.fprintf fmt "%d.%d" major minor
  let to_string (major, minor) = Printf.sprintf "%d.%d" major minor

  let from_string s =
    let err () =
      Error (`Msg (Format.sprintf "Invalid lockfile version: %S" s))
    in
    match String.lsplit2 ~on:'.' s with
    | None -> err ()
    | Some (major, minor) -> (
        match (int_of_string_opt major, int_of_string_opt minor) with
        | Some major, Some minor -> Ok (major, minor)
        | _ -> err ())

  let backward_compatible (major, minor) (major', minor') =
    major = major' && minor >= minor'

  let compatible t =
    (* We still support 0.1 lockfiles but we'll need to update that if we stop doing so *)
    if backward_compatible current t then Ok ()
    else
      Error
        (`Msg
          (Format.asprintf
             "Incompatible opam-monorepo lockfile version %a. Please upgrade \
              your opam-monorepo plugin."
             pp t))

  let to_opam_value t =
    Pos.with_default_pos (OpamParserTypes.FullPos.String (to_string t))

  let from_opam_value value =
    match (value : OpamParserTypes.FullPos.value) with
    | { pelem = String s; _ } -> from_string s
    | _ -> value_errorf ~value "Expected a string"

  let field = Extra_field.make ~name:"version" ~to_opam_value ~from_opam_value
end

module Root_packages = struct
  type t = OpamPackage.Name.Set.t

  let to_opam_value t =
    let open OpamParserTypes.FullPos in
    let sorted =
      t |> OpamPackage.Name.Set.elements
      |> List.map ~f:OpamPackage.Name.to_string
      |> List.sort ~cmp:String.compare
    in
    let pelem =
      List
        (Pos.with_default_pos
           (List.map ~f:(fun s -> Pos.with_default_pos (String s)) sorted))
    in
    Pos.with_default_pos pelem

  let from_opam_value value =
    let open Result.O in
    let open OpamParserTypes.FullPos in
    let elm_from_value { pelem; _ } =
      match pelem with
      | String s -> Ok (OpamPackage.Name.of_string s)
      | _ -> value_errorf ~value "Expected a string"
    in
    match value.pelem with
    | List { pelem; _ } ->
        Result.List.map ~f:elm_from_value pelem >>| OpamPackage.Name.Set.of_list
    | _ -> value_errorf ~value "Expected a list"

  let field =
    Extra_field.make ~name:"root-packages" ~to_opam_value ~from_opam_value
end

module Depends = struct
  type dependency = { package : OpamPackage.t; vendored : bool }
  type t = dependency list

  let from_package_summaries l =
    List.map l ~f:(fun summary ->
        let vendored =
          (not @@ Opam.Package_summary.is_base_package summary)
          && (not @@ Opam.Package_summary.is_virtual summary)
        in
        { vendored; package = summary.package })

  let variable_equal a b =
    String.equal (OpamVariable.to_string a) (OpamVariable.to_string b)

  let from_filtered_formula formula =
    let open OpamTypes in
    let atoms = OpamFormula.ands_to_list formula in
    Result.List.map atoms ~f:(function
      | Atom (name, Atom (Constraint (`Eq, FString version))) ->
          let version = OpamPackage.Version.of_string version in
          let package = OpamPackage.create name version in
          Ok { package; vendored = false }
      | Atom
          ( name,
            And
              ( Atom (Constraint (`Eq, FString version)),
                Atom (Filter (FIdent ([], var, None))) ) )
      | Atom
          ( name,
            And
              ( Atom (Filter (FIdent ([], var, None))),
                Atom (Constraint (`Eq, FString version)) ) )
        when variable_equal var Config.vendor_variable ->
          let version = OpamPackage.Version.of_string version in
          let package = OpamPackage.create name version in
          Ok { package; vendored = true }
      | _ ->
          Error
            (`Msg
              "Invalid opam-monorepo lockfile: depends should be expressed as \
               a list equality constraints optionally with a `vendor` variable"))

  let one_to_formula { package; vendored } : OpamTypes.filtered_formula =
    let name = package.name in
    let version = package.version in
    let variable =
      OpamFormula.Atom
        (OpamTypes.Filter (OpamTypes.FIdent ([], Config.vendor_variable, None)))
    in
    let version_constraint =
      OpamFormula.Atom
        (OpamTypes.Constraint
           (`Eq, OpamTypes.FString (OpamPackage.Version.to_string version)))
    in
    let formula =
      match vendored with
      | true -> OpamFormula.And (version_constraint, variable)
      | false -> version_constraint
    in
    Atom (name, formula)

  let to_filtered_formula xs =
    let sorted =
      List.sort
        ~cmp:(fun { package; _ } { package = package'; _ } ->
          OpamPackage.compare package package')
        xs
    in
    match sorted with
    | [] -> OpamFormula.Empty
    | hd :: tl ->
        List.fold_left tl
          ~f:(fun acc dep -> OpamFormula.And (acc, one_to_formula dep))
          ~init:(one_to_formula hd)
end

module Pin_depends = struct
  type t = (OpamPackage.t * OpamUrl.t) list

  let from_duniverse l =
    let open Duniverse.Repo in
    List.concat_map l ~f:(fun { provided_packages; url; _ } ->
        let url = Url.to_opam_url url in
        List.map provided_packages ~f:(fun p -> (p, url)))

  let sort t =
    List.sort ~cmp:(fun (pkg, _) (pkg', _) -> OpamPackage.compare pkg pkg') t
end

module Duniverse_dirs = struct
  type t = (string * OpamHash.t list) OpamUrl.Map.t

  let from_duniverse l =
    let open Duniverse.Repo in
    List.fold_left l ~init:OpamUrl.Map.empty
      ~f:(fun acc { dir; url; hashes; _ } ->
        OpamUrl.Map.add (Url.to_opam_url url) (dir, hashes) acc)

  let hash_to_opam_value hash =
    Pos.with_default_pos
      (OpamParserTypes.FullPos.String (OpamHash.to_string hash))

  let hash_from_opam_value value =
    let open OpamParserTypes.FullPos in
    match value with
    | { pelem = String s; pos } -> (
        match OpamHash.of_string_opt s with
        | Some hash -> Ok hash
        | None -> Pos.errorf ~pos "Invalid hash: %s" s)
    | _ -> value_errorf ~value "Expected a hash string representation"

  let from_opam_value value =
    let open OpamParserTypes.FullPos in
    let open Result.O in
    let elm_from_opam_value value =
      match value with
      | {
       pelem =
         List
           {
             pelem = [ { pelem = String url; _ }; { pelem = String dir; _ } ];
             _;
           };
       _;
      } ->
          Ok (OpamUrl.of_string url, (dir, []))
      | {
       pelem =
         List
           {
             pelem =
               [
                 { pelem = String url; _ };
                 { pelem = String dir; _ };
                 { pelem = List { pelem = hashes; _ }; _ };
               ];
             _;
           };
       _;
      } ->
          let* hashes = Result.List.map ~f:hash_from_opam_value hashes in
          Ok (OpamUrl.of_string url, (dir, hashes))
      | _ ->
          value_errorf ~value
            "Expected a list [ \"url\" \"repo name\" [<hashes>] ]"
    in
    match value with
    | { pelem = List { pelem = l; _ }; _ } ->
        let* bindings = Result.List.map ~f:elm_from_opam_value l in
        Ok (OpamUrl.Map.of_list bindings)
    | _ -> value_errorf ~value "Expected a list"

  let one_to_opam_value (url, (dir, hashes)) =
    let open OpamParserTypes.FullPos in
    let url = Pos.with_default_pos (String (OpamUrl.to_string url)) in
    let dir = Pos.with_default_pos (String dir) in
    let hashes = List.map ~f:hash_to_opam_value hashes in
    let list l = Pos.(with_default_pos (List (with_default_pos l))) in
    match hashes with
    | [] -> list [ url; dir ]
    | _ -> list [ url; dir; list hashes ]

  let to_opam_value t =
    let open OpamParserTypes.FullPos in
    let l = OpamUrl.Map.bindings t in
    Pos.with_default_pos
      (List (Pos.with_default_pos (List.map l ~f:one_to_opam_value)))

  let field =
    Extra_field.make ~name:"duniverse-dirs" ~to_opam_value ~from_opam_value
end

module Depexts = struct
  type t = (OpamSysPkg.Set.t * OpamTypes.filter) list

  let compare_elm (pkg_set, filter) (pkg_set', filter') =
    let c = OpamSysPkg.Set.compare pkg_set pkg_set' in
    if c = 0 then compare filter filter' else c

  let all ~root_depexts ~package_summaries =
    let transitive_depexts =
      List.map
        ~f:(fun { Opam.Package_summary.depexts; _ } -> depexts)
        package_summaries
    in
    let all = root_depexts @ transitive_depexts in
    List.concat all |> List.sort_uniq ~cmp:compare_elm
end

type t = {
  version : Version.t;
  root_packages : Root_packages.t;
  depends : Depends.t;
  pin_depends : Pin_depends.t;
  duniverse_dirs : Duniverse_dirs.t;
  depexts : Depexts.t;
}

let depexts t = t.depexts

let create ~root_packages ~package_summaries ~root_depexts ~duniverse () =
  let version = Version.current in
  let depends = Depends.from_package_summaries package_summaries in
  let pin_depends = Pin_depends.from_duniverse duniverse in
  let duniverse_dirs = Duniverse_dirs.from_duniverse duniverse in
  let depexts = Depexts.all ~root_depexts ~package_summaries in
  { version; root_packages; depends; pin_depends; duniverse_dirs; depexts }

let url_to_duniverse_url url =
  let url_res = Duniverse.Repo.Url.from_opam_url url in
  Result.map_error url_res ~f:(function `Msg msg ->
      let msg =
        Printf.sprintf "Invalid-monorepo lockfile pin URL %s: %s"
          (OpamUrl.to_string url) msg
      in
      `Msg msg)

let to_duniverse { duniverse_dirs; pin_depends; _ } =
  let open Result.O in
  let packages_per_url =
    List.fold_left pin_depends ~init:OpamUrl.Map.empty
      ~f:(fun acc (package, url) ->
        OpamUrl.Map.update url (fun l -> package :: l) [] acc)
    |> OpamUrl.Map.bindings
  in
  Result.List.map packages_per_url ~f:(fun (url, provided_packages) ->
      match OpamUrl.Map.find_opt url duniverse_dirs with
      | None ->
          let msg =
            Printf.sprintf
              "Invalid opam-monorepo lockfile: Missing dir for %s in %s"
              (OpamUrl.to_string url)
              (Extra_field.name Duniverse_dirs.field)
          in
          Error (`Msg msg)
      | Some (dir, hashes) ->
          let* url = url_to_duniverse_url url in
          Ok { Duniverse.Repo.dir; url; hashes; provided_packages })

let to_opam (t : t) =
  let open OpamFile.OPAM in
  empty
  |> with_maintainer [ "opam-monorepo" ]
  |> with_synopsis "opam-monorepo generated lockfile"
  |> with_depends (Depends.to_filtered_formula t.depends)
  |> with_pin_depends (Pin_depends.sort t.pin_depends)
  |> with_depexts t.depexts
  |> Extra_field.set Version.field t.version
  |> Extra_field.set Root_packages.field t.root_packages
  |> Extra_field.set Duniverse_dirs.field t.duniverse_dirs

let from_opam ?file opam =
  let open Result.O in
  let* version = Extra_field.get ?file Version.field opam in
  let* () = Version.compatible version in
  let* root_packages = Extra_field.get ?file Root_packages.field opam in
  let* depends = Depends.from_filtered_formula (OpamFile.OPAM.depends opam) in
  let pin_depends = OpamFile.OPAM.pin_depends opam in
  let* duniverse_dirs = Extra_field.get ?file Duniverse_dirs.field opam in
  let depexts = OpamFile.OPAM.depexts opam in
  Ok { version; root_packages; depends; pin_depends; duniverse_dirs; depexts }

let save ~file t =
  let opam = to_opam t in
  Bos.OS.File.with_oc file
    (fun oc () ->
      OpamFile.OPAM.write_to_channel oc opam;
      Ok ())
    ()
  |> Result.join

let load ~file =
  let open Result.O in
  let filename = Fpath.to_string file in
  let* opam =
    Bos.OS.File.with_ic file
      (fun ic () ->
        let filename = OpamFile.make (OpamFilename.of_string filename) in
        OpamFile.OPAM.read_from_channel ~filename ic)
      ()
  in
  from_opam ~file:filename opam
