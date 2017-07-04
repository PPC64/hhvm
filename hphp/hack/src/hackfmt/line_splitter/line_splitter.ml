(**
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Core

let expand_state state =
  let { Solve_state.chunk_group; rbm; _ } = state in
  let rule_ids = ISet.elements @@ Solve_state.get_candidate_rules state in

  let _, next_rbms = List.map_env rbm rule_ids ~f:(fun env_rbm rule_id ->
    if Solve_state.is_rule_bound state rule_id
    then env_rbm, None
    else begin
      let next_rbm_opt =
        Some (IMap.add rule_id true env_rbm)
          |> Option.filter ~f:(Chunk_group.are_rule_bindings_valid chunk_group)
      in
      let env_rbm = if Option.is_some next_rbm_opt
        then IMap.add rule_id false env_rbm
        else env_rbm
      in
      env_rbm, next_rbm_opt
    end
  ) in

  next_rbms
  |> List.filter_opt
  |> List.map ~f:(Solve_state.make chunk_group)

let find_best_state init_state =
  let queue = State_queue.make_empty 7 in
  List.iter (expand_state init_state) ~f:(State_queue.push queue);
  let rec aux count best =
    if
      State_queue.is_empty queue ||
      count > 2000 ||
      best.Solve_state.overflow = 0
    then best
    else
      let next_state = State_queue.pop queue in
      List.iter (expand_state next_state) ~f:(State_queue.push queue);
      aux (count + 1) (Solve_state.pick_best_state next_state best);
  in
  aux 0 init_state

let find_solve_states ?range chunk_groups =
  let chunk_groups = match range with
    | None -> chunk_groups
    | Some range ->
      List.filter chunk_groups ~f:(fun chunk_group ->
        let group_range = Chunk_group.get_char_range chunk_group in
        Interval.intervals_overlap range group_range
      )
  in
  chunk_groups |> List.map ~f:(fun chunk_group ->
    let rbm = Chunk_group.get_initial_rule_bindings chunk_group in
    let init_state = Solve_state.make chunk_group rbm in
    find_best_state init_state
  )

let print ?range solve_states =
  let formatted = solve_states
    |> List.map ~f:(State_printer.print_state ?range)
    |> String.concat ""
  in
  match range with
    | None -> formatted
    (* FIXME: This is a hack to work around the bizarre situation we're in,
     * where chunks are associated with the newline preceding them (because Bob
     * Nystrom suggested that that approach might be nicer than the
     * alternative), but chunk ranges associate tokens with the newline that
     * followed them (since that newline is in the token's trailing trivia).
     * Because chunks are associated with the split preceding them, printing a
     * range of chunks produces a newline before and not after. However, the
     * range we were provided associates newline characters with the line
     * preceding them, so the caller expects a newline after and not before. *)
    | Some _ -> (String_utils.lstrip formatted "\n") ^ "\n"

let solve ?range chunk_groups =
  chunk_groups
  |> find_solve_states ?range
  |> print ?range
