-- D-110: S-07 [Ipak grupni trening]. A Grupni member scanned outside their class gets an
-- unpaid gym visit (D-102). When the member was at a group class after all, for example
-- because the trainer moved the class that day, any staff role turns that visit into the
-- group visit it was: with the trainer and class chosen, linked to the group membership
-- that covers its day, using one of its sessions. The unpaid badge then no longer counts
-- it. No money changes hands, so no shift is needed. visits has no audit trigger, so the
-- change writes its own audit-log row (BR-096).

/**
 * D-110: turns an unlinked unpaid gym visit into a group visit with p_trainer and, when
 * p_class_time is given, that trainer's class at that time on the visit's weekday. The
 * membership is the one that covers group training on the visit's day (BR-053),
 * earliest end first (BR-074). Refused when the visit is not an unlinked unpaid gym
 * visit, the member already has a group visit that day, or no membership covers it.
 */
create function visit_to_group(p_visit uuid, p_trainer uuid, p_class_time time)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff := current_staff();
  v_old   visits;
  v_new   visits;
  v_day   date;
  v_ref   memberships;
  v_slot  uuid;
begin
  select * into v_old from visits where id = p_visit and gym_id = v_staff.gym_id;
  if not found then
    raise exception 'E_FORBIDDEN';
  end if;
  -- The member row lock serialises this with the member's check-ins and sales (BR-071).
  perform 1 from members where id = v_old.member_id and not is_anonymized for update;
  if not found then
    raise exception 'E_FORBIDDEN';
  end if;
  select * into v_old from visits where id = p_visit;

  if v_old.visit_type <> 'gym' or not v_old.is_unpaid or v_old.membership_id is not null then
    raise exception 'E_VISIT_NOT_UNPAID_GYM';
  end if;
  v_day := gym_local_date(v_old.gym_id, v_old.checked_in_at);

  -- One arrival is one visit: a group visit that day already counts the class.
  if exists (
    select 1 from visits v
    where v.member_id = v_old.member_id and v.visit_type = 'group'
      and gym_local_date(v.gym_id, v.checked_in_at) = v_day
  ) then
    raise exception 'E_GROUP_VISIT_EXISTS';
  end if;

  select m.* into v_ref
  from memberships m
  where m.member_id = v_old.member_id and membership_covers(m.id, 'group', v_day)
  order by m.end_date, m.created_at
  limit 1;
  if not found then
    raise exception 'E_NO_GROUP_MEMBERSHIP';
  end if;

  -- BR-075: a group trainer is required; the class is optional.
  if p_trainer is null then
    raise exception 'E_TRAINER_REQUIRED';
  end if;
  if not exists (select 1 from trainers where id = p_trainer and gym_id = v_staff.gym_id)
     or not trainer_can(p_trainer, 'group') then
    raise exception 'E_TRAINER_NOT_ASSIGNED';
  end if;
  if p_class_time is not null then
    select cs.id into v_slot
    from class_slots cs
    join programs pr on pr.id = cs.program_id and pr.kind = 'group'
    where cs.gym_id = v_staff.gym_id and cs.trainer_id = p_trainer and cs.is_active
      and cs.weekday = extract(isodow from v_day) and cs.starts_at = p_class_time
    limit 1;
    if v_slot is null then
      raise exception 'E_VALIDATION';
    end if;
  end if;

  -- is_unpaid stays true as history, as when a sale links a visit (D-106).
  update visits
  set visit_type = 'group', trainer_id = p_trainer, class_slot_id = v_slot,
      membership_id = v_ref.id
  where id = p_visit
  returning * into v_new;

  insert into audit_log (gym_id, table_name, row_id, action, old_data, new_data, changed_by)
  values (v_old.gym_id, 'visits', v_old.id::text, 'update', to_jsonb(v_old), to_jsonb(v_new),
          audit_actor());

  return json_build_object(
    'visit_id', v_new.id,
    'membership_id', v_ref.id,
    'unpaid_count', unlinked_unpaid_count(v_old.member_id)
  );
end;
$$;

-- Signed-in staff only; the function checks the gym itself (D-110: every role).
revoke execute on function visit_to_group(uuid, uuid, time) from public, anon;
