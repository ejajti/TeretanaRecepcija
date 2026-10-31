-- D-108 (BR-156): S-18 splits a trainer's Prihod into Prihod od grupnih and Prihod od
-- personalnih.
--
-- The owner decided on 31.10.2026 to see, per trainer and month, how much of the income
-- comes from group training and how much from personal training. Grupni and G+T are
-- group, as BR-155 splits them; Personalni is personal. The two always add up to the
-- trainer's revenue, which the function still returns for the S-18 chart.
--
-- This migration only replaces fin_trainer_stats with a version that returns two more
-- fields, revenue_group and revenue_personal. Every other field reads the same, so the
-- app that is running while it is applied keeps working. No table or row is changed.

/** S-18 (BR-156). D-104: Isplaćeno counts each payout in the month it is for. D-108: the
 *  revenue is also split into group (Grupni, G+T) and personal (Personalni). */
create or replace function fin_trainer_stats(p_month date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  v_staff staff := assert_owner();
  v_from  date := date_trunc('month', p_month)::date;
  v_to    date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_tz      text := (select timezone from gyms where id = v_staff.gym_id);
  -- D-90: the period as instants, measured once; see gym_day_start().
  v_start   timestamptz := gym_day_start(v_staff.gym_id, v_from);
  v_end     timestamptz := gym_day_start(v_staff.gym_id, v_to + 1);
begin
  return coalesce((
    select json_agg(row_to_json(t) order by t.trainer_name)
    from (
      select tr.id as trainer_id,
             tr.full_name as trainer_name,
             tr.is_active,
             (select count(distinct m.member_id)::int
              from payments pay
              join memberships m on m.id = pay.membership_id
              where pay.gym_id = v_staff.gym_id and pay.voided_at is null
                and pay.paid_on between v_from and v_to
                and m.trainer_id = tr.id) as clients,
             (select count(*)::int from (
                select distinct (v.checked_in_at at time zone v_tz)::date, v.class_slot_id
                from visits v
                where v.gym_id = v_staff.gym_id and v.visit_type = 'group'
                  and v.trainer_id = tr.id
                  and v.checked_in_at >= v_start and v.checked_in_at < v_end
              ) sessions) as group_sessions,
             (select count(*)::int from visits v
              where v.gym_id = v_staff.gym_id and v.visit_type = 'personal'
                and v.trainer_id = tr.id
                and v.checked_in_at >= v_start and v.checked_in_at < v_end
             ) as personal_sessions,
             coalesce(revenue.total, 0)::text as revenue,
             coalesce(revenue.group_total, 0)::text as revenue_group,
             coalesce(revenue.personal_total, 0)::text as revenue_personal,
             coalesce(revenue.trainer_total, 0)::text as trainer_total,
             coalesce(revenue.gym_total, 0)::text as gym_total,
             coalesce(revenue.undefined_count, 0) as undefined_count,
             coalesce(paid.total, 0)::text as paid_out,
             (coalesce(revenue.trainer_total, 0) - coalesce(paid.total, 0))::text as difference
      from trainers tr
      left join lateral (
        select sum(pay.amount) as total,
               -- D-108: personal is Personalni; everything else a trainer is paid for is
               -- group (Grupni, G+T), so the two always add up to the total.
               coalesce(sum(pay.amount) filter (where pay.plan_kind <> 'personal'), 0)
                 as group_total,
               coalesce(sum(pay.amount) filter (where pay.plan_kind = 'personal'), 0)
                 as personal_total,
               sum(case when (share).is_defined then (share).trainer_share end) as trainer_total,
               sum(case when (share).is_defined then (share).gym_share end) as gym_total,
               count(*) filter (where not (share).is_defined)::int as undefined_count
        from (
          select pay.amount, pl.kind as plan_kind,
                 membership_shares(m.id, pay.amount) as share
          from payments pay
          join memberships m on m.id = pay.membership_id
          join plans pl on pl.id = m.plan_id
          where pay.gym_id = v_staff.gym_id and pay.voided_at is null
            and pay.paid_on between v_from and v_to
            and m.trainer_id = tr.id
        ) pay
      ) revenue on true
      left join lateral (
        select sum(e.amount) as total
        from expenses e join expense_categories c on c.id = e.category_id
        where e.gym_id = v_staff.gym_id and e.voided_at is null
          and e.trainer_id = tr.id and c.is_salary
          -- D-104: a payout counts for the month it is for (a September salary paid
          -- on 5 October is September's Isplaćeno).
          and coalesce(e.cost_month, e.spent_on) between v_from and v_to
      ) paid on true
      where tr.gym_id = v_staff.gym_id
    ) t), '[]'::json);
end;
$$;
