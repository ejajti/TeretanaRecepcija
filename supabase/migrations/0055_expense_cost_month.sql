-- D-104 (BR-133, BR-151, BR-156, BR-158): Trošak za mjesec. An expense keeps the day it
-- was paid (spent_on), and may name the month it is for: the electricity bill for
-- September paid on 8 October is September's cost and October's payment. The income
-- statement, the owner's Troškovi and Profit cards, the chart and the trainers' Isplaćeno
-- take an expense in the month it is for; the cash flow, the expense list (S-17), the shift
-- and a manager's finance (D-80) keep the day it was paid.
--
-- An expense without a month of its own is for the day it was paid, exactly as before:
-- the 73 expenses already in the database get no value and read the same in every
-- report. A month of its own is the 1st of a month before the month paid, at most 12
-- months before; the month paid itself is stored as none. Goods bought through Nova roba
-- never have one: they are stock, not a cost (D-92).

-- A failed lock must not queue the desk behind this migration; it is simply run again.
set local lock_timeout = '5s';

-- Table -------------------------------------------------------------------------------
alter table expenses
  add column cost_month date,
  add constraint expenses_cost_month_check check (
    cost_month is null
    or (extract(day from cost_month) = 1
        and stock_movement_id is null
        and cost_month < date_trunc('month', spent_on::timestamp)::date
        and cost_month >= (date_trunc('month', spent_on::timestamp) - interval '12 months')::date));

-- D-90: the reports filter by the day an expense counts for.
create index expenses_cost_date_idx on expenses (gym_id, (coalesce(cost_month, spent_on)));

-- Recording ------------------------------------------------------------------------------

/**
 * BR-133 (D-98): the expense form, for every role; see migration 0048. D-104 adds
 * `p_cost_month`, the month the expense is for, last and optional, so a form from before
 * it records the month paid as before.
 */
drop function record_expense(uuid, text, numeric, date, payment_method, boolean, text,
                             text, boolean, uuid);

create function record_expense(
  p_category    uuid,
  p_description text,
  p_amount      numeric,
  p_spent_on    date,
  p_method      payment_method default null,
  p_from_till   boolean default false,
  p_supplier    text default null,
  p_invoice     text default null,
  p_vat         boolean default null,
  p_trainer     uuid default null,
  p_cost_month  date default null
)
returns expenses
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff    staff := current_staff();
  v_owner    boolean := v_staff.role in ('owner', 'admin');
  v_today    date := gym_today(v_staff.gym_id);
  v_category expense_categories;
  v_shift    uuid;
  v_spent    date := p_spent_on;
  v_method   payment_method := p_method;
  v_month    date;
  v_cost     date;
  v_expense  expenses;
begin
  select * into v_category from expense_categories
  where id = p_category and gym_id = v_staff.gym_id and is_active;
  if not found then
    raise exception 'E_VALIDATION';
  end if;
  if v_category.is_system or (v_category.is_salary and not v_owner) then
    raise exception 'E_CATEGORY_NOT_ALLOWED';
  end if;
  if char_length(coalesce(p_description, '')) not between 2 and 200
     or p_amount is null or p_amount < 0.01 or p_amount > 100000
     or v_spent is null or v_spent > v_today then
    raise exception 'E_VALIDATION';
  end if;
  -- BR-133: a trainer may be named only on a salary category, and must be this gym's.
  if p_trainer is not null then
    if not v_category.is_salary
       or not exists (select 1 from trainers where id = p_trainer and gym_id = v_staff.gym_id) then
      raise exception 'E_VALIDATION';
    end if;
  end if;

  if p_from_till then
    v_spent := v_today;
    v_method := 'cash';
  end if;
  if p_from_till or not v_owner then
    v_shift := (require_open_shift(v_staff.gym_id)).id;
  end if;

  -- D-104 (BR-133): the month the expense is for, the month it was paid or one of the 12
  -- before it. The month it was paid is stored as no month of its own, as every expense
  -- entered before D-104 is.
  v_month := date_trunc('month', v_spent::timestamp)::date;
  if p_cost_month is not null then
    if extract(day from p_cost_month) <> 1 or p_cost_month > v_month
       or p_cost_month < (v_month - interval '12 months')::date then
      raise exception 'E_VALIDATION';
    end if;
    v_cost := nullif(p_cost_month, v_month);
  end if;

  insert into expenses (
    gym_id, spent_on, category_id, description, amount, method, paid_from_till,
    supplier, invoice_number, vat_included, trainer_id, created_by, shift_id, cost_month
  ) values (
    v_staff.gym_id, v_spent, p_category, p_description, round(p_amount, 2), v_method,
    coalesce(p_from_till, false), nullif(p_supplier, ''), nullif(p_invoice, ''), p_vat,
    p_trainer, v_staff.id, v_shift, v_cost
  )
  returning * into v_expense;
  return v_expense;
end;
$$;

-- Signed-in staff only; record_expense checks the role and the gym itself (D-98).
revoke execute on function
  record_expense(uuid, text, numeric, date, payment_method, boolean, text, text, boolean,
                 uuid, date)
  from public, anon;

-- Finance (owner and admin; a manager's view is what was paid) ------------------------------

/**
 * S-16 (D-92, D-103): the owner's income statement and cash flow. D-104: operating
 * expenses by the month they are for, Ostala plaćanja by the day they were paid.
 */
create or replace function fin_statement(p_from date, p_to date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  v_staff       staff := assert_owner();
  v_today       date;
  v_start       timestamptz;
  v_end         timestamptz;
  v_memberships numeric(12,2);
  v_training    numeric(12,2);
  v_other       numeric(12,2);
  v_storage     numeric(12,2);
  v_cogs        numeric(12,2);
  v_shrinkage   numeric(12,2);
  v_income      numeric(12,2);
  v_operating   numeric(12,2);
  v_other_paid  numeric(12,2);
  v_goods_paid  numeric(12,2);
  v_stock_date  date;
  v_stock_value numeric(12,2);
begin
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'E_VALIDATION';
  end if;
  v_today := gym_today(v_staff.gym_id);
  -- D-90: the period as instants, measured once; see gym_day_start().
  v_start := gym_day_start(v_staff.gym_id, p_from);
  v_end   := gym_day_start(v_staff.gym_id, p_to + 1);

  select coalesce(sum(amount) filter (where grp = 'memberships'), 0),
         coalesce(sum(amount) filter (where grp = 'training'), 0),
         coalesce(sum(amount) filter (where grp = 'other'), 0)
  into v_memberships, v_training, v_other
  from (
    select pay.amount,
           case
             when pay.kind = 'day_pass' then 'memberships'
             when pay.kind = 'membership' and pl.kind = 'gym' then 'memberships'
             when pay.kind = 'membership' and pl.kind in ('group', 'combo', 'personal')
               then 'training'
             else 'other'
           end as grp
    from payments pay
    left join plans pl on pl.id = pay.plan_id
    where pay.gym_id = v_staff.gym_id and pay.voided_at is null
      and pay.paid_on between p_from and p_to
  ) grouped;

  -- D-103: goods short are a cost (positive), goods found lower it.
  select coalesce(sum(quantity * unit_price) filter (where type = 'out'), 0),
         coalesce(sum(quantity * unit_cost) filter (where type = 'out'), 0),
         coalesce(sum(-quantity * unit_cost) filter (where type = 'adjust'), 0)
  into v_storage, v_cogs, v_shrinkage
  from stock_movements
  where gym_id = v_staff.gym_id and type in ('out', 'adjust') and voided_at is null
    and created_at >= v_start and created_at < v_end;

  -- D-104 (BR-151, BR-158): the statement takes an operating expense in the month it is
  -- for, the cash flow on the day it was paid; without a month of its own, both are the
  -- day it was paid. Goods bought (BR-141) are always the day paid.
  select coalesce(sum(amount) filter (where stock_movement_id is null
                                        and coalesce(cost_month, spent_on) between p_from and p_to), 0),
         coalesce(sum(amount) filter (where stock_movement_id is null
                                        and spent_on between p_from and p_to), 0),
         coalesce(sum(amount) filter (where stock_movement_id is not null
                                        and spent_on between p_from and p_to), 0)
  into v_operating, v_other_paid, v_goods_paid
  from expenses
  where gym_id = v_staff.gym_id and voided_at is null
    and (spent_on between p_from and p_to
         or coalesce(cost_month, spent_on) between p_from and p_to);

  v_income := v_memberships + v_training + v_storage + v_other;
  v_stock_date := least(p_to, v_today);
  select coalesce(sum(value), 0) into v_stock_value
  from product_stock_at(v_staff.gym_id, v_stock_date);

  return json_build_object(
    'income', json_build_object(
      'memberships', v_memberships::text,
      'training', v_training::text,
      'storage', v_storage::text,
      'other', v_other::text,
      'total', v_income::text
    ),
    'cogs', v_cogs::text,
    'shrinkage', v_shrinkage::text,
    'gross_profit', (v_income - v_cogs - v_shrinkage)::text,
    'operating', coalesce((
      select json_agg(json_build_object('name', t.name, 'total', t.total::text)
                      order by t.total desc, t.name)
      from (
        select c.name, sum(e.amount) as total
        from expenses e join expense_categories c on c.id = e.category_id
        where e.gym_id = v_staff.gym_id and e.voided_at is null
          and coalesce(e.cost_month, e.spent_on) between p_from and p_to
          and e.stock_movement_id is null
        group by c.name
      ) t), '[]'::json),
    'operating_total', v_operating::text,
    'profit', (v_income - v_cogs - v_shrinkage - v_operating)::text,
    'cash_flow', json_build_object(
      'received', v_income::text,
      'goods_paid', v_goods_paid::text,
      'other_paid', v_other_paid::text,
      'net_change', (v_income - v_goods_paid - v_other_paid)::text
    ),
    'stock_value', v_stock_value::text,
    'stock_value_date', to_char(v_stock_date, 'YYYY-MM-DD')
  );
end;
$$;

/**
 * S-16 cards (D-80, D-92, D-103). D-104: the owner's Troškovi and Profit take operating
 * expenses by the month they are for; a manager's Troškovi stay what was paid.
 */
create or replace function fin_summary(p_from date, p_to date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  v_staff     staff := assert_finance_period(p_from, p_to);
  v_manager   boolean := v_staff.role = 'manager';
  v_payments  numeric(10,2);
  v_sales     numeric(10,2);
  v_cogs      numeric(10,2);
  v_shrinkage numeric(10,2);
  v_expenses  numeric(10,2);
  v_operating numeric(10,2);
  v_today     date := gym_today(v_staff.gym_id);
  -- D-90: the period as instants, measured once; see gym_day_start().
  v_start   timestamptz := gym_day_start(v_staff.gym_id, p_from);
  v_end     timestamptz := gym_day_start(v_staff.gym_id, p_to + 1);
begin
  select coalesce(sum(amount), 0) into v_payments
  from payments
  where gym_id = v_staff.gym_id and voided_at is null and paid_on between p_from and p_to;

  select coalesce(sum(quantity * unit_price) filter (where type = 'out'), 0),
         coalesce(sum(quantity * unit_cost) filter (where type = 'out'), 0),
         coalesce(sum(-quantity * unit_cost) filter (where type = 'adjust'), 0)
  into v_sales, v_cogs, v_shrinkage
  from stock_movements
  where gym_id = v_staff.gym_id and type in ('out', 'adjust') and voided_at is null
    and created_at >= v_start and created_at < v_end;

  -- D-77: salaries never reach a manager, not even inside a total. D-104: a manager's
  -- expenses are what was paid in the period; the owner's operating expenses are those
  -- for the period, by the month they are for.
  select coalesce(sum(e.amount) filter (where e.spent_on between p_from and p_to), 0),
         coalesce(sum(e.amount) filter (where e.stock_movement_id is null
                                          and coalesce(e.cost_month, e.spent_on)
                                              between p_from and p_to), 0)
  into v_expenses, v_operating
  from expenses e
  join expense_categories c on c.id = e.category_id
  where e.gym_id = v_staff.gym_id and e.voided_at is null
    and (e.spent_on between p_from and p_to
         or coalesce(e.cost_month, e.spent_on) between p_from and p_to)
    and (not v_manager or not c.is_salary);

  -- BR-157 and D-77: no profit, bar profit or member count for a manager.
  if v_manager then
    return json_build_object(
      'income', (v_payments + v_sales)::text,
      'expenses', v_expenses::text
    );
  end if;

  return json_build_object(
    'income', (v_payments + v_sales)::text,
    -- BR-151 to BR-153 (D-92, D-103): what the period cost, not what it paid for stock.
    'expenses', (v_cogs + v_shrinkage + v_operating)::text,
    'profit', (v_payments + v_sales - v_cogs - v_shrinkage - v_operating)::text,
    'bar_profit', (v_sales - v_cogs)::text,
    'active_members', (
      select count(*) from members m
      where m.gym_id = v_staff.gym_id and not m.is_anonymized
        and exists (
          select 1 from memberships ms
          where ms.member_id = m.id
            -- D-90: only a membership that can be active today is asked about; any
            -- other is voided, upcoming or expired by membership_status() itself.
            and ms.voided_at is null
            and ms.start_date <= v_today and ms.end_date >= v_today
            and membership_status(ms.id, v_today) = 'active')
    )
  );
end;
$$;

/** S-16 chart (D-68). D-104: an expense for an earlier month is a cost of that month. */
create or replace function fin_chart(p_year integer, p_month integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  v_staff      staff := assert_owner();
  v_today      date := gym_today(v_staff.gym_id);
  -- BR-001: "future" is measured against the gym's today, never the server's.
  v_unit       text := case when p_month is null then 'month' else 'day' end;
  v_from       date;
  v_to         date;
  v_first_year integer;
  v_tz         text;
  v_start      timestamptz;
  v_end        timestamptz;
begin
  if p_year is null or p_year < 2000 or p_year > extract(year from v_today)
     or (p_month is not null and (p_month < 1 or p_month > 12)) then
    raise exception 'E_VALIDATION';
  end if;

  v_from := make_date(p_year, coalesce(p_month, 1), 1);
  -- A month that has not started yet has nothing to show.
  if v_from > v_today then
    raise exception 'E_VALIDATION';
  end if;
  v_to := case
            when p_month is null then make_date(p_year, 12, 31)
            else (v_from + interval '1 month' - interval '1 day')::date
          end;
  -- D-90: the period as instants, measured once; see gym_day_start().
  select timezone into v_tz from gyms where id = v_staff.gym_id;
  v_start := gym_day_start(v_staff.gym_id, v_from);
  v_end   := gym_day_start(v_staff.gym_id, v_to + 1);

  -- The year selector reaches back to the first year that holds any money. BR-095:
  -- voided rows count nowhere, so they do not stretch the selector either.
  v_first_year := extract(year from least(
    (select min(paid_on) from payments
     where gym_id = v_staff.gym_id and voided_at is null),
    (select min(coalesce(cost_month, spent_on)) from expenses
     where gym_id = v_staff.gym_id and voided_at is null),
    (select gym_local_date(v_staff.gym_id, min(created_at)) from stock_movements
     where gym_id = v_staff.gym_id and type = 'out' and voided_at is null),
    v_today))::integer;

  return (
    with slots as (
      select slot::date as slot
      from generate_series(v_from, v_to, ('1 ' || v_unit)::interval) as slot
    ),
    income as (
      -- BR-150: membership and other payments by payment date (D-27), plus bar sales.
      select date_trunc(v_unit, paid_on::timestamp)::date as slot, amount
      from payments
      where gym_id = v_staff.gym_id and voided_at is null
        and paid_on between v_from and v_to
      union all
      select date_trunc(v_unit, (created_at at time zone v_tz)::date::timestamp)::date,
             quantity * unit_price
      from stock_movements
      where gym_id = v_staff.gym_id and type = 'out' and voided_at is null
        and created_at >= v_start and created_at < v_end
    ),
    spent as (
      -- BR-151 (D-92): operating expenses by the day they were spent, or (D-104) on the
      -- 1st of the month they are for; a stock-in's expense is not one.
      select date_trunc(v_unit, coalesce(cost_month, spent_on)::timestamp)::date as slot,
             amount
      from expenses
      where gym_id = v_staff.gym_id and voided_at is null
        and coalesce(cost_month, spent_on) between v_from and v_to
        and stock_movement_id is null
      union all
      -- BR-153 (D-92): the cost of the goods sold, on the day they were sold; D-103:
      -- Manjak robe, on the day the stock was counted (goods found lower it).
      select date_trunc(v_unit, (created_at at time zone v_tz)::date::timestamp)::date,
             case when type = 'out' then quantity * unit_cost else -quantity * unit_cost end
      from stock_movements
      where gym_id = v_staff.gym_id and type in ('out', 'adjust') and voided_at is null
        and created_at >= v_start and created_at < v_end
    ),
    points as (
      select s.slot,
             coalesce(i.total, 0)::numeric(12,2) as income,
             coalesce(e.total, 0)::numeric(12,2) as expenses
      from slots s
      left join (select slot, sum(amount) as total from income group by slot) i
        using (slot)
      left join (select slot, sum(amount) as total from spent group by slot) e
        using (slot)
    )
    select json_build_object(
      'year', p_year,
      'month', p_month,
      'first_year', v_first_year,
      -- A slot after today is null, not zero: the chart leaves it empty instead of
      -- drawing a month that has not happened as a month without income.
      'points', json_agg(json_build_object(
                  'date', to_char(p.slot, 'YYYY-MM-DD'),
                  'income', case when p.slot > v_today then null else p.income::text end,
                  'expenses', case when p.slot > v_today then null else p.expenses::text end)
                order by p.slot),
      'income', sum(p.income)::numeric(12,2)::text,
      'expenses', sum(p.expenses)::numeric(12,2)::text,
      'profit', (sum(p.income) - sum(p.expenses))::numeric(12,2)::text)
    from points p
  );
end;
$$;

/** S-18 (BR-156). D-104: Isplaćeno counts each payout in the month it is for. */
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
             coalesce(revenue.trainer_total, 0)::text as trainer_total,
             coalesce(revenue.gym_total, 0)::text as gym_total,
             coalesce(revenue.undefined_count, 0) as undefined_count,
             coalesce(paid.total, 0)::text as paid_out,
             (coalesce(revenue.trainer_total, 0) - coalesce(paid.total, 0))::text as difference
      from trainers tr
      left join lateral (
        select sum(pay.amount) as total,
               sum(case when (share).is_defined then (share).trainer_share end) as trainer_total,
               sum(case when (share).is_defined then (share).gym_share end) as gym_total,
               count(*) filter (where not (share).is_defined)::int as undefined_count
        from (
          select pay.amount, membership_shares(m.id, pay.amount) as share
          from payments pay
          join memberships m on m.id = pay.membership_id
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

/** S-17 (D-63, D-80, D-93, D-96). D-104: each row names the month it is for, if any. */
create or replace function fin_expenses(p_from date, p_to date, p_category uuid DEFAULT NULL::uuid, p_method text DEFAULT NULL::text, p_created_by uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  v_staff   staff := assert_finance_period(p_from, p_to);
  v_manager boolean := v_staff.role = 'manager';
begin
  return coalesce((
    select json_agg(row_to_json(t) order by t.spent_on desc, t.created_at desc)
    from (
      select e.id,
             e.spent_on,
             e.cost_month,
             c.name as category_name,
             c.is_salary,
             e.description,
             e.supplier,
             e.invoice_number,
             e.method,
             e.paid_from_till,
             e.vat_included,
             e.amount::text as amount,
             tr.full_name as trainer_name,
             e.created_by,
             s.full_name as created_by_name,
             e.stock_movement_id,
             e.recurring_expense_id,
             e.shift_id,
             e.created_at,
             e.voided_at,
             e.void_reason
      from expenses e
      join expense_categories c on c.id = e.category_id
      join staff s on s.id = e.created_by
      left join trainers tr on tr.id = e.trainer_id
      where e.gym_id = v_staff.gym_id
        and e.spent_on between p_from and p_to
        and (not v_manager or not c.is_salary)
        and (p_category is null or e.category_id = p_category)
        and (p_method is null
             or (p_method = 'none' and e.method is null)
             or e.method::text = p_method)
        and (p_created_by is null or e.created_by = p_created_by)
    ) t), '[]'::json);
end;
$$;
