(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module F = Format
module L = Logging
module MF = MarkupFormatter
module Domain = StarvationDomain

let pname_pp = MF.wrap_monospaced Typ.Procname.pp

let attrs_of_pname = Summary.OnDisk.proc_resolve_attributes

module Payload = SummaryPayload.Make (struct
  type t = Domain.summary

  let field = Payloads.Fields.starvation
end)

(* using an indentifier for a class object, create an access path representing that lock;
   this is for synchronizing on Java class objects only *)
let lock_of_class =
  let typ = Typ.(mk (Tstruct Name.Java.java_lang_class)) in
  let typ' = Typ.(mk (Tptr (typ, Pk_pointer))) in
  fun class_id ->
    let ident = Ident.create_normal class_id 0 in
    AccessPath.of_id ident typ'


module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = Domain

  type extras = FormalMap.t

  let exec_instr (astate : Domain.t) {ProcData.summary; tenv; extras} _ (instr : HilInstr.t) =
    let open ConcurrencyModels in
    let open StarvationModels in
    let log_parse_error error pname actuals =
      L.debug Analysis Verbose "%s pname:%a actuals:%a@." error Typ.Procname.pp pname
        (PrettyPrintable.pp_collection ~pp_item:HilExp.pp)
        actuals
    in
    let get_lock_path = function
      | HilExp.AccessExpression access_exp -> (
        match HilExp.AccessExpression.to_access_path access_exp with
        | (((Var.ProgramVar pvar, _) as base), _) as path
          when FormalMap.is_formal base extras || Pvar.is_global pvar ->
            Some (AccessPath.inner_class_normalize path)
        | _ ->
            (* ignore paths on local or logical variables *)
            None )
      | HilExp.Constant (Const.Cclass class_id) ->
          (* this is a synchronized/lock(CLASSNAME.class) construct *)
          Some (lock_of_class class_id)
      | _ ->
          None
    in
    let procname = Summary.get_proc_name summary in
    let is_java = Typ.Procname.is_java procname in
    let do_lock locks loc astate =
      List.filter_map ~f:get_lock_path locks |> Domain.acquire tenv astate ~procname ~loc
    in
    let do_unlock locks astate = List.filter_map ~f:get_lock_path locks |> Domain.release astate in
    let do_call callee loc astate =
      Payload.read ~caller_summary:summary ~callee_pname:callee
      |> Option.value_map ~default:astate ~f:(fun callee_summary ->
             Domain.integrate_summary tenv ~caller_summary:astate ~callee_summary ~callee ~loc )
    in
    match instr with
    | Assign _ | Assume _ | Call (_, Indirect _, _, _, _) | Metadata _ ->
        astate
    | Call (_, Direct callee, actuals, _, _) when should_skip_analysis tenv callee actuals ->
        astate
    | Call (_, Direct callee, actuals, _, loc) -> (
      match get_lock_effect callee actuals with
      | Lock locks ->
          do_lock locks loc astate
      | GuardLock guard ->
          Domain.lock_guard tenv astate guard ~procname ~loc
      | GuardConstruct {guard; lock; acquire_now} -> (
        match get_lock_path lock with
        | Some lock_path ->
            Domain.add_guard tenv astate guard lock_path ~acquire_now ~procname ~loc
        | None ->
            log_parse_error "Couldn't parse lock in guard constructor" callee actuals ;
            astate )
      | Unlock locks ->
          do_unlock locks astate
      | GuardUnlock guard ->
          Domain.unlock_guard astate guard
      | GuardDestroy guard ->
          Domain.remove_guard astate guard
      | LockedIfTrue _ | GuardLockedIfTrue _ ->
          astate
      | NoEffect when is_synchronized_library_call tenv callee ->
          (* model a synchronized call without visible internal behaviour *)
          let locks = List.hd actuals |> Option.to_list in
          do_lock locks loc astate |> do_unlock locks
      | NoEffect when is_java && is_ui_thread_model callee ->
          Domain.set_on_ui_thread astate
      | NoEffect when is_java && is_strict_mode_violation tenv callee actuals ->
          Domain.strict_mode_call ~callee ~loc astate
      | NoEffect when is_java -> (
        match may_block tenv callee actuals with
        | Some sev ->
            Domain.blocking_call ~callee sev ~loc astate
        | None ->
            do_call callee loc astate )
      | NoEffect ->
          (* in C++/Obj C we only care about deadlocks, not starvation errors *)
          do_call callee loc astate )


  let pp_session_name _node fmt = F.pp_print_string fmt "starvation"
end

module Analyzer = LowerHil.MakeAbstractInterpreter (TransferFunctions (ProcCfg.Normal))

let analyze_procedure {Callbacks.exe_env; summary} =
  let proc_desc = Summary.get_proc_desc summary in
  let procname = Procdesc.get_proc_name proc_desc in
  let tenv = Exe_env.get_tenv exe_env procname in
  if StarvationModels.should_skip_analysis tenv procname [] then summary
  else
    let formals = FormalMap.make proc_desc in
    let proc_data = ProcData.make summary tenv formals in
    let loc = Procdesc.get_loc proc_desc in
    let initial =
      if not (Procdesc.is_java_synchronized proc_desc) then Domain.bottom
      else
        let lock =
          match procname with
          | Typ.Procname.Java java_pname when Typ.Procname.Java.is_static java_pname ->
              (* this is crafted so as to match synchronized(CLASSNAME.class) constructs *)
              Typ.Procname.Java.get_class_type_name java_pname
              |> Typ.Name.name |> Ident.string_to_name |> lock_of_class |> Option.some
          | _ ->
              FormalMap.get_formal_base 0 formals |> Option.map ~f:(fun base -> (base, []))
        in
        Domain.acquire tenv Domain.bottom ~procname ~loc (Option.to_list lock)
    in
    let initial =
      if ConcurrencyModels.runs_on_ui_thread ~attrs_of_pname tenv procname then
        Domain.set_on_ui_thread initial
      else initial
    in
    let filter_blocks =
      if StarvationModels.is_annotated_nonblocking ~attrs_of_pname tenv procname then
        Domain.filter_blocking_calls
      else Fn.id
    in
    Analyzer.compute_post proc_data ~initial
    |> Option.map ~f:filter_blocks
    |> Option.value_map ~default:summary ~f:(fun astate -> Payload.update_summary astate summary)


(** per-procedure report map, which takes care of deduplication *)
module ReportMap : sig
  type t

  val empty : t

  type report_add_t = Typ.Procname.t -> Location.t -> Errlog.loc_trace -> string -> t -> t

  val add_deadlock : report_add_t

  val add_starvation : StarvationModels.severity -> report_add_t

  val add_strict_mode_violation : report_add_t

  val add_lockless_violation : report_add_t

  val log : IssueLog.t -> Tenv.t -> Procdesc.t -> t -> IssueLog.t
end = struct
  type problem =
    | Starvation of StarvationModels.severity
    | Deadlock of int
    | StrictModeViolation of int
    | LocklessViolation of int

  type report_t = {problem: problem; pname: Typ.Procname.t; ltr: Errlog.loc_trace; message: string}

  module LocMap = PrettyPrintable.MakePPMap (Location)

  type t = report_t list LocMap.t

  type report_add_t = Typ.Procname.t -> Location.t -> Errlog.loc_trace -> string -> t -> t

  let empty : t = LocMap.empty

  let add loc report map =
    let reports = try LocMap.find loc map with Caml.Not_found -> [] in
    let new_reports = report :: reports in
    LocMap.add loc new_reports map


  let add_deadlock pname loc ltr message (map : t) =
    let report = {problem= Deadlock (-List.length ltr); pname; ltr; message} in
    add loc report map


  let add_starvation sev pname loc ltr message map =
    let report = {pname; problem= Starvation sev; ltr; message} in
    add loc report map


  let add_strict_mode_violation pname loc ltr message (map : t) =
    let report = {problem= StrictModeViolation (-List.length ltr); pname; ltr; message} in
    add loc report map


  let add_lockless_violation pname loc ltr message (map : t) =
    let report = {problem= LocklessViolation (-List.length ltr); pname; ltr; message} in
    add loc report map


  let log start_issue_log tenv pdesc map =
    let log_report ~issue_log loc {problem; pname; ltr; message} =
      let issue_type =
        match problem with
        | Deadlock _ ->
            IssueType.deadlock
        | Starvation _ ->
            IssueType.starvation
        | StrictModeViolation _ ->
            IssueType.strict_mode_violation
        | LocklessViolation _ ->
            IssueType.lockless_violation
      in
      if Reporting.is_suppressed tenv pdesc issue_type then issue_log
      else
        Reporting.log_issue_external ~issue_log pname Exceptions.Error ~loc ~ltr issue_type message
    in
    let mk_deduped_report ({message} as report) =
      { report with
        message= Printf.sprintf "%s Additional report(s) on the same line were suppressed." message
      }
    in
    let log_reports compare loc reports issue_log =
      if Config.deduplicate then
        match reports with
        | [] ->
            issue_log
        | [(_, report)] ->
            log_report ~issue_log loc report
        | reports ->
            List.max_elt ~compare reports
            |> Option.fold ~init:issue_log ~f:(fun acc (_, rep) ->
                   mk_deduped_report rep |> log_report ~issue_log:acc loc )
      else
        List.fold reports ~init:issue_log ~f:(fun acc (_, rep) -> log_report ~issue_log:acc loc rep)
    in
    let filter_map_deadlock = function {problem= Deadlock l} as r -> Some (l, r) | _ -> None in
    let filter_map_starvation = function
      | {problem= Starvation s} as r ->
          Some (s, r)
      | _ ->
          None
    in
    let filter_map_strict_mode_violation = function
      | {problem= StrictModeViolation l} as r ->
          Some (l, r)
      | _ ->
          None
    in
    let filter_map_lockless_violation = function
      | {problem= LocklessViolation l} as r ->
          Some (l, r)
      | _ ->
          None
    in
    let compare_reports weight_compare (w, r) (w', r') =
      match weight_compare w w' with 0 -> String.compare r.message r'.message | result -> result
    in
    let log_location loc problems issue_log =
      let deadlocks = List.filter_map problems ~f:filter_map_deadlock in
      let starvations = List.filter_map problems ~f:filter_map_starvation in
      let strict_mode_violations = List.filter_map problems ~f:filter_map_strict_mode_violation in
      let lockless_violations = List.filter_map problems ~f:filter_map_lockless_violation in
      log_reports (compare_reports Int.compare) loc deadlocks issue_log
      |> log_reports (compare_reports Int.compare) loc lockless_violations
      |> log_reports (compare_reports StarvationModels.compare_severity) loc starvations
      |> log_reports (compare_reports Int.compare) loc strict_mode_violations
    in
    LocMap.fold log_location map start_issue_log
end

let should_report_deadlock_on_current_proc current_elem endpoint_elem =
  (not Config.deduplicate)
  ||
  let open Domain in
  match (endpoint_elem.CriticalPair.elem.event, current_elem.CriticalPair.elem.event) with
  | _, (MayBlock _ | StrictModeCall _) | (MayBlock _ | StrictModeCall _), _ ->
      (* should never happen *)
      L.die InternalError "Deadlock cannot occur without two lock events: %a" CriticalPair.pp
        current_elem
  | LockAcquire ((Var.LogicalVar _, _), []), _ ->
      (* first elem is a class object (see [lock_of_class]), so always report because the
         reverse ordering on the events will not occur -- FIXME WHY? *)
      true
  | LockAcquire ((Var.LogicalVar _, _), _ :: _), _ | _, LockAcquire ((Var.LogicalVar _, _), _) ->
      (* first elem has an ident root, but has a non-empty access path, which means we are
         not filtering out local variables (see [exec_instr]), or,
         second elem has an ident root, which should not happen if we are filtering locals *)
      L.die InternalError "Deadlock cannot occur on these logical variables: %a @." CriticalPair.pp
        current_elem
  | LockAcquire ((_, typ1), _), LockAcquire ((_, typ2), _) ->
      (* use string comparison on types as a stable order to decide whether to report a deadlock *)
      let c = String.compare (Typ.to_string typ1) (Typ.to_string typ2) in
      c < 0
      || Int.equal 0 c
         && (* same class, so choose depending on location *)
            Location.compare current_elem.CriticalPair.loc endpoint_elem.CriticalPair.loc < 0


let should_report pdesc =
  Procdesc.get_access pdesc <> PredSymb.Private
  &&
  match Procdesc.get_proc_name pdesc with
  | Typ.Procname.Java java_pname ->
      (not (Typ.Procname.Java.is_autogen_method java_pname))
      && not (Typ.Procname.Java.is_class_initializer java_pname)
  | Typ.Procname.ObjC_Cpp _ ->
      true
  | _ ->
      false


let fold_reportable_summaries (tenv, current_summary) clazz ~init ~f =
  let methods =
    Tenv.lookup tenv clazz
    |> Option.value_map ~default:[] ~f:(fun tstruct -> tstruct.Typ.Struct.methods)
  in
  let f acc mthd =
    Ondemand.get_proc_desc mthd
    |> Option.value_map ~default:acc ~f:(fun other_pdesc ->
           if should_report other_pdesc then
             Payload.read ~caller_summary:current_summary ~callee_pname:mthd
             |> Option.map ~f:(fun payload -> (mthd, payload))
             |> Option.fold ~init:acc ~f
           else acc )
  in
  List.fold methods ~init ~f


(*  Note about how many times we report a deadlock: normally twice, at each trace starting point.
    Due to the fact we look for deadlocks in the summaries of the class at the root of a path,
    this will fail when (a) the lock is of class type (ie as used in static sync methods), because
    then the root is an identifier of type java.lang.Class and (b) when the lock belongs to an
    inner class but this is no longer obvious in the path, because of nested-class path normalisation.
    The net effect of the above issues is that we will only see these locks in conflicting pairs
    once, as opposed to twice with all other deadlock pairs. *)

(** report warnings possible on the parallel composition of two threads/critical pairs 
    [should_report_starvation] means [pair] is on the UI thread and not on a constructor *)
let report_on_parallel_composition ~should_report_starvation pname pair lock other_pname other_pair
    report_map =
  let open Domain in
  if CriticalPair.can_run_in_parallel pair other_pair then
    let acquisitions = other_pair.CriticalPair.elem.acquisitions in
    match other_pair.CriticalPair.elem.event with
    | MayBlock (block_descr, sev)
      when should_report_starvation && Acquisitions.lock_is_held lock acquisitions ->
        let error_message =
          Format.asprintf
            "Method %a runs on UI thread and%a, which may be held by another thread which %s."
            pname_pp pname Lock.pp_locks lock block_descr
        in
        let first_trace = CriticalPair.make_trace ~header:"[Trace 1] " pname pair in
        let second_trace = CriticalPair.make_trace ~header:"[Trace 2] " other_pname other_pair in
        let ltr = first_trace @ second_trace in
        let loc = CriticalPair.get_earliest_lock_or_call_loc ~procname:pname pair in
        ReportMap.add_starvation sev pname loc ltr error_message report_map
    | LockAcquire other_lock
      when CriticalPair.may_deadlock pair other_pair
           && should_report_deadlock_on_current_proc pair other_pair ->
        let error_message =
          Format.asprintf
            "Potential deadlock. %a (Trace 1) and %a (Trace 2) acquire locks %a and %a in reverse \
             orders."
            pname_pp pname pname_pp other_pname Lock.describe lock Lock.describe other_lock
        in
        let first_trace = CriticalPair.make_trace ~header:"[Trace 1] " pname pair in
        let second_trace = CriticalPair.make_trace ~header:"[Trace 2] " other_pname other_pair in
        let ltr = first_trace @ second_trace in
        let loc = CriticalPair.get_earliest_lock_or_call_loc ~procname:pname pair in
        ReportMap.add_deadlock pname loc ltr error_message report_map
    | _ ->
        report_map
  else report_map


let report_on_pair ((tenv, summary) as env) (pair : Domain.CriticalPair.t) report_map =
  let open Domain in
  let pname = Summary.get_proc_name summary in
  let event = pair.elem.event in
  let should_report_starvation =
    CriticalPair.is_uithread pair && not (Typ.Procname.is_constructor pname)
  in
  match event with
  | MayBlock (_, sev) when should_report_starvation ->
      let error_message =
        Format.asprintf "Method %a runs on UI thread and may block; %a." pname_pp pname
          Event.describe event
      in
      let loc = CriticalPair.get_loc pair in
      let ltr = CriticalPair.make_trace ~include_acquisitions:false pname pair in
      ReportMap.add_starvation sev pname loc ltr error_message report_map
  | StrictModeCall _ when should_report_starvation ->
      let error_message =
        Format.asprintf "Method %a runs on UI thread and may violate Strict Mode; %a." pname_pp
          pname Event.describe event
      in
      let loc = CriticalPair.get_loc pair in
      let ltr = CriticalPair.make_trace ~include_acquisitions:false pname pair in
      ReportMap.add_strict_mode_violation pname loc ltr error_message report_map
  | LockAcquire _ when StarvationModels.is_annotated_lockless ~attrs_of_pname tenv pname ->
      let error_message =
        Format.asprintf "Method %a is annotated %s but%a." pname_pp pname
          (MF.monospaced_to_string Annotations.lockless)
          Event.describe event
      in
      let loc = CriticalPair.get_earliest_lock_or_call_loc ~procname:pname pair in
      let ltr = CriticalPair.make_trace pname pair in
      ReportMap.add_lockless_violation pname loc ltr error_message report_map
  | LockAcquire lock when Acquisitions.lock_is_held lock pair.elem.acquisitions ->
      let error_message =
        Format.asprintf "Potential self deadlock. %a%a twice." pname_pp pname Lock.pp_locks lock
      in
      let loc = CriticalPair.get_earliest_lock_or_call_loc ~procname:pname pair in
      let ltr = CriticalPair.make_trace ~header:"In method " pname pair in
      ReportMap.add_deadlock pname loc ltr error_message report_map
  | LockAcquire lock ->
      Lock.owner_class lock
      |> Option.value_map ~default:report_map ~f:(fun other_class ->
             (* get the class of the root variable of the lock in the lock acquisition
                and retrieve all the summaries of the methods of that class;
                then, report on the parallel composition of the current pair and any pair in these 
                summaries that can indeed run in parallel *)
             fold_reportable_summaries env other_class ~init:report_map
               ~f:(fun acc (other_pname, {critical_pairs}) ->
                 CriticalPairs.fold
                   (report_on_parallel_composition ~should_report_starvation pname pair lock
                      other_pname)
                   critical_pairs acc ) )
  | _ ->
      report_map


let reporting {Callbacks.procedures; source_file} =
  let report_on_summary env (summary : Domain.t) report_map =
    Domain.CriticalPairs.fold (report_on_pair env) summary.critical_pairs report_map
  in
  let report_procedure issue_log ((tenv, summary) as env) =
    let proc_desc = Summary.get_proc_desc summary in
    if should_report proc_desc then
      Payload.read_toplevel_procedure (Procdesc.get_proc_name proc_desc)
      |> Option.value_map ~default:issue_log ~f:(fun summary ->
             report_on_summary env summary ReportMap.empty
             |> ReportMap.log issue_log tenv proc_desc )
    else issue_log
  in
  List.fold procedures ~init:IssueLog.empty ~f:report_procedure
  |> IssueLog.store ~dir:Config.starvation_issues_dir_name ~file:source_file
