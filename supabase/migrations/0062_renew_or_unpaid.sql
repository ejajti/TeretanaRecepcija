-- D-109: a scan (or a manual start) of a member whose membership has expired, or whose
-- sessions of the type are used up, records nothing at once. S-03f asks the desk:
-- [Produži članarinu] sells the membership and checks the member in with it in the same
-- transaction; [Neplaćeni dolazak] records the unpaid visit as a scan did until now
-- (BR-073, D-106); [Otkaži] records nothing and the member scans again.
--
-- 1. check_in_choice: the visit auto_check_in records (migration 0058), decided without
--    recording it, and whether it is a D-109 renewal. auto_check_in now records that
--    choice, so registration and [Neplaćeni dolazak] record exactly what a scan did.
-- 2. start_check_in: a renewal answers 'renew' (start_check_in_renew) with no visit.
-- 3. check_in_unpaid: S-03f [Neplaćeni dolazak].
-- 4. check_in_after_sale: the "Prijavi odmah" check-in of register_member (D-106),
--    shared with sell_membership's new p_check_in (S-03f [Produži članarinu]). When the
--    member's memberships then cover two types, it takes the type of the membership just
--    sold, which for a new G+T member is Teretana, as before.
--
-- A Grupni-only member outside their class still gets an unpaid gym visit at once
-- (D-102): renewing the Grupni would not cover it. S-03a is unchanged.

/**
 * D-102, D-106 (BR-073): the visit a scan records without a question, as json
 * {type, membership, trainer, slot, renew, ref}, or null when S-03a is needed.
 * `membership` is set only for a covered group or personal visit; a gym visit takes the
 * BR-074 default in perform_check_in. D-109: `renew` is true when the visit would be
 * unpaid because nothing is valid today or the type's sessions are used up, and `ref` is
 * then the membership to renew: the one that ended last (null when there is none), or
 * the used-up one.
 */
create function check_in_choice(p_staff staff, p_member uuid)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_today date := gym_today(p_staff.gym_id);
  v_gym   boolean;
  v_group boolean;
  v_pers  boolean;
  v_type  visit_type;
  v_ref   memberships;
  v_last  memberships;
  v_paid  boolean;
  v_slot  uuid;
begin
  select coalesce(bool_or(m.covers_gym), false),
         coalesce(bool_or(m.covers_group), false),
         coalesce(bool_or(m.covers_personal), false)
  into v_gym, v_group, v_pers
  from memberships m
  where m.member_id = p_member and m.voided_at is null
    and v_today between m.start_date and m.end_date;

  -- Two or more types (G+T, or Teretana with Grupni or Personalni) need S-03a.
  if v_gym::int + v_group::int + v_pers::int >= 2 then
    return null;
  end if;

  -- Nothing valid (BR-078): an unpaid visit, which D-109 offers to renew.
  if not (v_gym or v_group or v_pers) then
    select m.* into v_last
    from memberships m
    where m.member_id = p_member and m.voided_at is null and m.end_date < v_today
    order by m.end_date desc, m.created_at desc
    limit 1;

    -- D-106: after a Grupni or Personalni only, of that type with its trainer.
    if v_last.trainer_id is not null and not v_last.covers_gym then
      if v_last.covers_personal and not v_last.covers_group
         and trainer_can(v_last.trainer_id, 'personal') then
        return json_build_object(
          'type', 'personal', 'membership', null, 'trainer', v_last.trainer_id,
          'slot', null, 'renew', true, 'ref', v_last.id
        );
      end if;
      if v_last.covers_group and not v_last.covers_personal
         and trainer_can(v_last.trainer_id, 'group') then
        v_slot := member_class_slot(p_staff.gym_id, v_last.trainer_id, v_last.class_time);
        if v_slot is not null then
          return json_build_object(
            'type', 'group', 'membership', null, 'trainer', v_last.trainer_id,
            'slot', v_slot, 'renew', true, 'ref', v_last.id
          );
        end if;
      end if;
    end if;

    return json_build_object(
      'type', 'gym', 'membership', null, 'trainer', null, 'slot', null,
      'renew', true, 'ref', v_last.id
    );
  end if;

  -- Teretana only: the BR-074 default; unpaid when every gym visit is used up.
  if v_gym then
    select m.* into v_ref
    from memberships m
    where m.member_id = p_member and m.voided_at is null and m.covers_gym
      and v_today between m.start_date and m.end_date
    order by membership_covers(m.id, 'gym', v_today) desc, m.end_date desc, m.created_at desc
    limit 1;
    v_paid := membership_covers(v_ref.id, 'gym', v_today);
    return json_build_object(
      'type', 'gym', 'membership', null, 'trainer', null, 'slot', null,
      'renew', not v_paid, 'ref', v_ref.id
    );
  end if;

  v_type := case when v_group then 'group' else 'personal' end;
  -- The membership the visit belongs to: one that still covers the type, earliest end
  -- first (BR-074); with every one used up, the one valid today, for its trainer and class.
  select m.* into v_ref
  from memberships m
  where m.member_id = p_member and m.voided_at is null
    and v_today between m.start_date and m.end_date
    and case v_type when 'group' then m.covers_group else m.covers_personal end
  order by membership_covers(m.id, v_type, v_today) desc, m.end_date, m.created_at
  limit 1;
  v_paid := membership_covers(v_ref.id, v_type, v_today);

  -- BR-075, BR-076: the trainer is required; one who no longer qualifies is chosen on S-03a.
  if v_ref.trainer_id is null
     or not trainer_can(v_ref.trainer_id, v_type::text::program_kind) then
    return null;
  end if;

  if v_type = 'personal' then
    return json_build_object(
      'type', 'personal', 'membership', case when v_paid then v_ref.id end,
      'trainer', v_ref.trainer_id, 'slot', null, 'renew', not v_paid, 'ref', v_ref.id
    );
  end if;

  v_slot := member_class_slot(p_staff.gym_id, v_ref.trainer_id, v_ref.class_time);
  if v_slot is null then
    -- Outside the member's class: an unpaid gym visit (BR-078, D-102), not a renewal.
    return json_build_object(
      'type', 'gym', 'membership', null, 'trainer', null, 'slot', null,
      'renew', false, 'ref', v_ref.id
    );
  end if;
  return json_build_object(
    'type', 'group', 'membership', case when v_paid then v_ref.id end,
    'trainer', v_ref.trainer_id, 'slot', v_slot, 'renew', not v_paid, 'ref', v_ref.id
  );
end;
$$;

/**
 * D-102, D-106: records the visit check_in_choice decides, or returns null when S-03a is
 * needed. The same visits as migration 0058 recorded.
 */
create or replace function auto_check_in(p_staff staff, p_member uuid, p_manual boolean)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_choice json := check_in_choice(p_staff, p_member);
begin
  if v_choice is null then
    return null;
  end if;
  return perform_check_in(
    p_staff, p_member, (v_choice ->> 'type')::visit_type, (v_choice ->> 'membership')::uuid,
    (v_choice ->> 'trainer')::uuid, (v_choice ->> 'slot')::uuid, p_manual
  );
end;
$$;

/**
 * D-109: S-03f's question, with no visit recorded. `reason` is 'expired' (the membership
 * that ended last), 'used_up' (valid, with no session left of the type) or 'none' (no
 * membership has ever run); `renewal` holds what S-08 preselects; `unpaid_count` is the
 * unlinked unpaid visits the member already has.
 */
create function start_check_in_renew(
  p_member uuid,
  p_manual boolean,
  p_pause_ended boolean,
  p_ref uuid
)
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'result', 'renew',
    'member', member_brief(p_member),
    'manual', coalesce(p_manual, false),
    'reason', case
      when m.id is null then 'none'
      when m.end_date < gym_today(m.gym_id) then 'expired'
      else 'used_up'
    end,
    'plan_name', p.name,
    'end_date', m.end_date,
    'unpaid_count', unlinked_unpaid_count(p_member),
    'renewal', case when m.id is not null then json_build_object(
      'plan_id', m.plan_id,
      'trainer_id', m.trainer_id,
      'class_time', m.class_time
    ) end,
    'trainer_defaults', check_in_options(p_member) -> 'trainer_defaults',
    'pause_ended', p_pause_ended
  )
  from (select p_ref as id) as r
  left join memberships m on m.id = r.id
  left join plans p on p.id = m.plan_id;
$$;

/**
 * BR-073: a scan or a manual start. S-03a when the member's memberships cover two types,
 * D-109's question when the visit would be unpaid for an expired or used-up membership,
 * otherwise the visit at once.
 */
create or replace function start_check_in(p_staff staff, p_member uuid, p_manual boolean)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ended  boolean := end_member_pauses(p_member, gym_today(p_staff.gym_id));
  v_choice json := check_in_choice(p_staff, p_member);
begin
  if v_choice is null then
    return start_check_in_choose(p_member, p_manual, v_ended);
  end if;
  -- D-109: nothing is recorded until the desk chooses on S-03f.
  if (v_choice ->> 'renew')::boolean then
    return start_check_in_renew(p_member, p_manual, v_ended, (v_choice ->> 'ref')::uuid);
  end if;
  return json_build_object(
    'result', 'checked_in',
    'check_in', perform_check_in(
      p_staff, p_member, (v_choice ->> 'type')::visit_type,
      (v_choice ->> 'membership')::uuid, (v_choice ->> 'trainer')::uuid,
      (v_choice ->> 'slot')::uuid, p_manual
    ),
    'pause_ended', v_ended
  );
end;
$$;

/**
 * D-109: S-03f [Neplaćeni dolazak]. Records the visit the scan held back, as a scan
 * records it (BR-073, D-106); S-03a when the memberships have meanwhile come to cover
 * two types.
 */
create function check_in_unpaid(p_member uuid, p_manual boolean)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff := current_staff();
  v_ended boolean;
  v_visit json;
begin
  if not exists (select 1 from members where id = p_member and gym_id = v_staff.gym_id
                 and not is_anonymized) then
    raise exception 'E_FORBIDDEN';
  end if;
  v_ended := end_member_pauses(p_member, gym_today(v_staff.gym_id));
  v_visit := auto_check_in(v_staff, p_member, p_manual);
  if v_visit is null then
    return start_check_in_choose(p_member, p_manual, v_ended);
  end if;
  return json_build_object('result', 'checked_in', 'check_in', v_visit, 'pause_ended', v_ended);
end;
$$;

/**
 * D-106, D-109: the check-in that follows a sale ("Prijavi odmah" on S-05, [Produži
 * članarinu] on S-03f), or null when none is recorded: the membership just sold is not
 * valid today, or it is Grupni only and its trainer holds no class today. A Grupni-only
 * membership checks the member in to their class today at any hour; any other is checked
 * in as a scan would, and where the memberships then cover two types, with the type of
 * the membership just sold.
 */
create function check_in_after_sale(
  p_staff staff,
  p_member uuid,
  p_membership uuid,
  p_manual boolean
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := gym_today(p_staff.gym_id);
  v_new   memberships;
  v_slot  uuid;
  v_type  visit_type;
  v_visit json;
begin
  select * into v_new from memberships where id = p_membership;
  if v_today not between v_new.start_date and v_new.end_date then
    return null;
  end if;

  if v_new.covers_group and not v_new.covers_gym and not v_new.covers_personal then
    v_slot := trainer_class_today(p_staff.gym_id, v_new.trainer_id, v_new.class_time);
    if v_slot is null then
      return null;
    end if;
    -- Unpaid visits the sale linked may have used up its sessions (BR-052 step 2).
    return perform_check_in(
      p_staff, p_member, 'group',
      case when membership_covers(v_new.id, 'group', v_today) then v_new.id end,
      v_new.trainer_id, v_slot, p_manual
    );
  end if;

  v_visit := auto_check_in(p_staff, p_member, p_manual);
  if v_visit is null then
    v_type := case
      when v_new.covers_gym then 'gym'
      when v_new.covers_group then 'group'
      else 'personal'
    end;
    v_visit := perform_check_in(
      p_staff, p_member, v_type,
      case when membership_covers(v_new.id, v_type, v_today) then v_new.id end,
      case when v_type <> 'gym' then v_new.trainer_id end,
      case when v_type = 'group' then default_class_slot(p_staff.gym_id, v_new.trainer_id) end,
      p_manual
    );
  end if;
  return v_visit;
end;
$$;

/**
 * F-06 with "Prijavi odmah" (D-31, US-06.1 AC2), as in migration 0058; the check-in is
 * check_in_after_sale's.
 */
create or replace function register_member(
  p_card_code text,
  p_first text,
  p_last text,
  p_phone text,
  p_email text,
  p_dob date,
  p_plan uuid,
  p_trainer uuid,
  p_amount numeric,
  p_sessions integer,
  p_method payment_method,
  p_check_in boolean default false,
  p_class_time time default null,
  p_start_override date default null,
  p_gym_fee numeric default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff  staff := current_staff();
  v_shift  shifts := require_open_shift(v_staff.gym_id);
  v_card   cards;
  v_fields members;
  v_number integer;
  v_member members;
  v_sale   json;
  v_visit  json;
begin
  v_card := unassigned_card(v_staff.gym_id, p_card_code);
  v_fields := clean_member(v_staff.gym_id, p_first, p_last, p_phone, p_email, p_dob);

  -- BR-042: sequential per gym, never reused; the row lock serialises registrations.
  insert into member_counters (gym_id, last_number) values (v_staff.gym_id, 1)
  on conflict (gym_id) do update set last_number = member_counters.last_number + 1
  returning last_number into v_number;

  insert into members (
    gym_id, member_number, first_name, last_name, phone, email, date_of_birth, created_by
  ) values (
    v_staff.gym_id, v_number, v_fields.first_name, v_fields.last_name, v_fields.phone,
    v_fields.email, v_fields.date_of_birth, v_staff.id
  )
  returning * into v_member;

  update cards
  set status = 'active', member_id = v_member.id, assigned_at = now()
  where id = v_card.id;

  v_sale := membership_sale(
    v_staff, v_shift.id, v_member.id, p_plan, p_trainer, p_amount, p_sessions, p_method,
    p_start_override, null, false, p_class_time, p_gym_fee
  );

  if coalesce(p_check_in, false) then
    v_visit := check_in_after_sale(
      v_staff, v_member.id, (v_sale ->> 'membership_id')::uuid, false
    );
  end if;

  return json_build_object(
    'member_id', v_member.id,
    'member_number', v_member.member_number,
    'first_name', v_member.first_name,
    'last_name', v_member.last_name,
    'membership', v_sale,
    'check_in', v_visit
  );
end;
$$;

-- sell_membership gains p_check_in and p_manual, so its signature changes.
drop function sell_membership(uuid, uuid, uuid, numeric, integer, payment_method, date, time,
                              numeric);

/**
 * F-08 (BR-050 to BR-060). D-109: with p_check_in (S-03f [Produži članarinu]) the member
 * is checked in with the membership just sold, in the same transaction; `check_in` holds
 * the visit, or `not_checked_in` says why there is none: 'inside' (another desk checked
 * the member in meanwhile), 'not_today' (the membership starts later) or 'no_class' (a
 * Grupni whose trainer holds no class today).
 */
create function sell_membership(
  p_member uuid,
  p_plan uuid,
  p_trainer uuid,
  p_amount numeric,
  p_sessions integer,
  p_method payment_method,
  p_start_override date default null,
  p_class_time time default null,
  p_gym_fee numeric default null,
  p_check_in boolean default false,
  p_manual boolean default false
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff := current_staff();
  v_shift shifts := require_open_shift(v_staff.gym_id);
  v_sale  json;
  v_visit json;
  v_skip  text;
begin
  -- The member row lock keeps two sales for one member from computing the same start.
  perform 1 from members
  where id = p_member and gym_id = v_staff.gym_id and not is_anonymized
  for update;
  if not found then
    raise exception 'E_FORBIDDEN';
  end if;

  v_sale := membership_sale(
    v_staff, v_shift.id, p_member, p_plan, p_trainer, p_amount, p_sessions, p_method,
    p_start_override, null, false, p_class_time, p_gym_fee
  );
  if not coalesce(p_check_in, false) then
    return v_sale;
  end if;

  if exists (select 1 from visits where member_id = p_member and checked_out_at is null) then
    v_skip := 'inside';
  else
    v_visit := check_in_after_sale(
      v_staff, p_member, (v_sale ->> 'membership_id')::uuid, p_manual
    );
    if v_visit is null then
      v_skip := case
        when gym_today(v_staff.gym_id) between (v_sale ->> 'start_date')::date
                                           and (v_sale ->> 'end_date')::date
          then 'no_class'
        else 'not_today'
      end;
    end if;
  end if;

  return (v_sale::jsonb || jsonb_build_object('check_in', v_visit, 'not_checked_in', v_skip))::json;
end;
$$;

-- Function privileges ---------------------------------------------------------------------
-- Internal: only other security definer functions call these. auto_check_in,
-- start_check_in and register_member keep their privileges (create or replace).
revoke execute on function
  check_in_choice(staff, uuid),
  start_check_in_renew(uuid, boolean, boolean, uuid),
  check_in_after_sale(staff, uuid, uuid, boolean)
  from public, anon, authenticated;

-- Signed-in staff only; each RPC checks the role and the gym itself.
revoke execute on function
  check_in_unpaid(uuid, boolean),
  sell_membership(uuid, uuid, uuid, numeric, integer, payment_method, date, time, numeric,
                  boolean, boolean)
  from public, anon;
