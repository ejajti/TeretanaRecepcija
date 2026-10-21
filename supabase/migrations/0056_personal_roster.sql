-- D-105 (BR-027a): S-29 Treneri, tab Personalni.
--
-- The owner decided on 21.10.2026 that S-29 also shows every role which members are
-- assigned to which trainer for personal training, so it is no longer necessary to open
-- each member's profile to see it. The tab lists the personal memberships that are valid
-- today or start later, with the day paid, the last valid day and the personal sessions
-- left.
--
-- This migration only adds a function that reads. No table, row or existing function is
-- changed, so the S-29 Grupni roster (trainer_roster) and everything else read the same.
--
-- The amounts are the owner's (BR-157): personal_roster returns none. The owner's and
-- the admin's column comes from the existing fin_roster_prices, which starts with the
-- owner check like every other fin_ function (doc 08 §2).

/**
 * BR-027a: the personal roster for the caller's gym, as of gym today (BR-001).
 *
 * - trainers: every active trainer assigned to an active personal program (BR-023),
 *             shown even with no members;
 * - members:  the personal memberships that are not voided and whose last day is today
 *             or later (valid today or upcoming), one per membership, with the personal
 *             visits counted on it as BR-054 counts them (membership_used).
 */
create function personal_roster()
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff staff := current_staff();
  v_today date := gym_today(v_staff.gym_id);
begin
  return json_build_object(
    'today', v_today,
    'trainers', coalesce((
      select json_agg(row_to_json(t) order by t.trainer_name, t.trainer_id)
      from (
        select distinct tr.id as trainer_id,
               tr.full_name as trainer_name
        from trainers tr
        join trainer_programs tp on tp.trainer_id = tr.id
        join programs p on p.id = tp.program_id
        where tr.gym_id = v_staff.gym_id
          and tr.is_active
          and p.is_active
          and p.kind = 'personal'
      ) t
    ), '[]'::json),
    'members', coalesce((
      select json_agg(row_to_json(r)
                      order by r.trainer_name, r.trainer_id, r.last_name, r.first_name,
                               r.member_number, r.start_date, r.membership_id)
      from (
        select ms.id as membership_id,
               ms.trainer_id,
               tr.full_name as trainer_name,
               m.id as member_id,
               m.member_number,
               m.first_name,
               m.last_name,
               pl.name as plan_name,
               pay.paid_on,
               ms.start_date,
               ms.end_date,
               ms.personal_session_limit,
               membership_used(ms.id, 'personal') as personal_used
        from memberships ms
        join members m on m.id = ms.member_id
        join plans pl on pl.id = ms.plan_id
        join trainers tr on tr.id = ms.trainer_id
        left join payments pay on pay.membership_id = ms.id and pay.voided_at is null
        where ms.gym_id = v_staff.gym_id
          and ms.covers_personal
          and ms.voided_at is null
          and not m.is_anonymized
          and ms.end_date >= v_today
      ) r
    ), '[]'::json)
  );
end;
$$;

-- Signed-in staff only; current_staff() refuses anyone who is not staff.
revoke execute on function personal_roster() from public, anon;
