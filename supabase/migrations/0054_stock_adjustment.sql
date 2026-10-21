-- D-103 (BR-145): Poravnanje stanja. When the goods on the shelf and the stock level in
-- the app disagree (whey that broke, expired or went missing, or bottles found that were
-- never entered), the owner, the admin or the manager enters on S-13 what was counted.
-- The difference is written as a stock movement of type 'adjust' (migration 0053) with
-- its own sign: −5 for five bags short, +2 for two found.
--
-- An adjustment is not money: it has no expense, no payment and no shift (BR-092), and
-- the cash flow does not move (BR-158), since the goods were paid for at Nova roba. What
-- was lost is valued at the purchase price of that moment (AS-6) and is a cost of its
-- day, `Manjak robe`, in the income statement under the cost of goods sold: it lowers
-- gross profit and profit (BR-152); goods found raise them. The stock value follows the
-- stock level by itself (BR-159). Bar profit stays the margin on sales (BR-153).
--
-- Every row already in stock_movements is a stock-in or a sale, and each of them reads
-- the same after this migration: the checks below only admit the new type, and the stock
-- level gives stock-ins and sales the same signs as before.

-- A failed lock must not queue the desk behind this migration; it is simply run again.
set local lock_timeout = '5s';

-- Table -------------------------------------------------------------------------------
alter table stock_movements
  drop constraint stock_movements_quantity_check,
  drop constraint stock_movements_check3;

alter table stock_movements
  add column counted_qty   integer,  -- adjust: what was counted (BR-145)
  add column adjust_reason text,     -- adjust: why the stock differed
  add column note          text,     -- adjust: optional, required for 'other'
  -- Stock-ins and sales are 1–10,000 units as before; an adjustment is the signed
  -- difference, never zero.
  add constraint stock_movements_quantity_check check (
    case when type = 'adjust' then quantity <> 0 else quantity between 1 and 10000 end),
  -- A sale still needs its shift; a stock-in may have one, an adjustment has none.
  add constraint stock_movements_out_shift_check check (type <> 'out' or shift_id is not null),
  add constraint stock_movements_adjust_check check (
    case when type = 'adjust'
         then counted_qty is not null and adjust_reason is not null and shift_id is null
         else counted_qty is null and adjust_reason is null and note is null
    end),
  add constraint stock_movements_counted_qty_check check (counted_qty between 0 and 10000),
  add constraint stock_movements_adjust_reason_check check (
    adjust_reason in ('damaged', 'expired', 'internal_use', 'count', 'other')),
  add constraint stock_movements_note_check check (char_length(note) between 1 and 200);

-- Stock level -------------------------------------------------------------------------

/** BR-143 (D-103): stock-ins add, sales take away, an adjustment carries its own sign. */
create or replace function product_stock(p_product uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(case when m.type = 'out' then -m.quantity else m.quantity end), 0)::int
  from stock_movements m
  where m.product_id = p_product and m.voided_at is null;
$$;

/**
 * BR-159: each product's stock level and value at the end of `p_date`, the gym's day.
 * The price is the one a sale would have taken then (AS-6): the current purchase price
 * on the gym's today, and for an earlier day the price of the last stock-in before that
 * day ended, or the current price when there was none. Only other functions call it.
 * D-103: adjustments count in the stock level with their own sign.
 */
create or replace function product_stock_at(p_gym uuid, p_date date)
returns table (product_id uuid, stock integer, price numeric, value numeric)
language sql
stable
security definer
set search_path = public
as $$
  with bounds as (
    select gym_day_start(p_gym, p_date + 1) as day_end,
           p_date >= gym_today(p_gym) as is_today
  )
  select p.id,
         st.stock,
         pr.price,
         round(st.stock * pr.price, 2)
  from products p
  cross join bounds b
  cross join lateral (
    select coalesce(sum(case when m.type = 'out' then -m.quantity else m.quantity end), 0)::int
             as stock
    from stock_movements m
    where m.product_id = p.id and m.voided_at is null and m.created_at < b.day_end
  ) st
  cross join lateral (
    select case
             when b.is_today then p.current_purchase_price
             else coalesce((
               select m.unit_cost from stock_movements m
               where m.product_id = p.id and m.type = 'in' and m.voided_at is null
                 and m.created_at < b.day_end
               order by m.created_at desc
               limit 1), p.current_purchase_price)
           end as price
  ) pr
  where p.gym_id = p_gym;
$$;

-- Adjusting and voiding -----------------------------------------------------------------

/**
 * D-103 (BR-145, P-45): S-13 [Poravnaj stanje]. The owner, the admin or the manager
 * enters what was counted; the difference to the stock level is written as an
 * adjustment at today's purchase price. `p_expected` is the stock level the dialog
 * showed: if a sale or a stock-in has changed it since, the count no longer matches and
 * E_STOCK_CHANGED carries the stock level now, so it is counted again instead of an
 * adjustment silently swallowing that sale.
 *
 * Reasons: 'damaged' (Oštećeno), 'expired' (Istekao rok), 'internal_use' (Potrošeno u
 * teretani) for goods short only; 'count' (Manjak or Višak pri popisu) and 'other'
 * (Ostalo, with a note of 3–200 characters) either way.
 */
create function adjust_stock(p_product uuid, p_counted integer, p_expected integer,
                             p_reason text, p_note text default null)
returns stock_movements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff    staff := current_staff();
  v_note     text := nullif(btrim(coalesce(p_note, '')), '');
  v_product  products;
  v_stock    integer;
  v_diff     integer;
  v_movement stock_movements;
begin
  if v_staff.role not in ('owner', 'admin', 'manager') then
    raise exception 'E_FORBIDDEN';
  end if;
  if p_counted is null or p_counted not between 0 and 10000 or p_expected is null
     or p_reason is null
     or p_reason not in ('damaged', 'expired', 'internal_use', 'count', 'other')
     or coalesce(char_length(v_note), 0) > 200
     or (p_reason = 'other' and coalesce(char_length(v_note), 0) < 3) then
    raise exception 'E_VALIDATION';
  end if;

  -- The product row lock serialises this with sales and stock-ins (stock_sale).
  select * into v_product from products
  where id = p_product and gym_id = v_staff.gym_id and is_active
  for update;
  if not found then
    raise exception 'E_VALIDATION';
  end if;

  v_stock := product_stock(p_product);
  if v_stock <> p_expected then
    raise exception 'E_STOCK_CHANGED' using detail = v_stock::text;
  end if;
  v_diff := p_counted - v_stock;
  if v_diff = 0 or (v_diff > 0 and p_reason not in ('count', 'other')) then
    raise exception 'E_VALIDATION';
  end if;

  insert into stock_movements (gym_id, product_id, type, quantity, unit_cost,
                               counted_qty, adjust_reason, note, created_by)
  values (v_staff.gym_id, p_product, 'adjust', v_diff, v_product.current_purchase_price,
          p_counted, p_reason, v_note, v_staff.id)
  returning * into v_movement;
  return v_movement;
end;
$$;

/**
 * BR-095: voids a sale (any role, AS-14), a stock-in or (D-103) an adjustment (the owner
 * and the admin). A voided stock-in voids its expense with it. Neither a stock-in nor
 * goods found may be voided once that would leave the stock below zero; voiding goods
 * short puts them back.
 */
create or replace function void_stock_movement(p_movement uuid, p_reason text)
returns stock_movements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff    staff := current_staff();
  v_movement stock_movements;
  v_reason   text;
begin
  select * into v_movement from stock_movements
  where id = p_movement and gym_id = v_staff.gym_id
  for update;
  if not found then
    raise exception 'E_FORBIDDEN';
  end if;
  if v_movement.type in ('in', 'adjust') and v_staff.role not in ('owner', 'admin') then
    raise exception 'E_FORBIDDEN';
  end if;
  if v_movement.voided_at is not null or not record_editable(v_staff, v_movement.shift_id) then
    raise exception 'E_RECORD_NOT_EDITABLE';
  end if;
  v_reason := void_reason_text(p_reason);

  if v_movement.type = 'in' or (v_movement.type = 'adjust' and v_movement.quantity > 0) then
    perform 1 from products where id = v_movement.product_id for update;
    if product_stock(v_movement.product_id) - v_movement.quantity < 0 then
      raise exception 'E_STOCK_NEGATIVE';
    end if;
  end if;
  if v_movement.type = 'in' then
    update expenses
    set voided_at = now(), voided_by = v_staff.id, void_reason = v_reason
    where stock_movement_id = p_movement and voided_at is null;
  end if;

  update stock_movements
  set voided_at = now(), voided_by = v_staff.id, void_reason = v_reason
  where id = p_movement
  returning * into v_movement;
  return v_movement;
end;
$$;

-- Finance (owner and admin; a manager's view is unchanged) -------------------------------

/**
 * S-16 (D-92): the owner's income statement and cash flow for a period.
 *
 * - Income (BR-150) by group: Članarine (gym plans and day passes), Treninzi (group,
 *   G+T and personal plans), Prodaja iz magacina, Ostalo (card replacements).
 * - Cost of goods sold (BR-153), Manjak robe (D-103, BR-145), gross profit, operating
 *   expenses by category (BR-151, every expense but a stock-in's) and profit (BR-152).
 * - Cash flow (BR-158): what came in, what was paid for new goods, what was paid for
 *   everything else. An adjustment moves no money.
 * - Stock value at the end of the period, or today for a period that reaches it (BR-159).
 */
create or replace function fin_statement(p_from date, p_to date)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
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

  select coalesce(sum(amount) filter (where stock_movement_id is null), 0),
         coalesce(sum(amount) filter (where stock_movement_id is not null), 0)
  into v_operating, v_goods_paid
  from expenses
  where gym_id = v_staff.gym_id and voided_at is null
    and spent_on between p_from and p_to;

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
          and e.spent_on between p_from and p_to
          and e.stock_movement_id is null
        group by c.name
      ) t), '[]'::json),
    'operating_total', v_operating::text,
    'profit', (v_income - v_cogs - v_shrinkage - v_operating)::text,
    'cash_flow', json_build_object(
      'received', v_income::text,
      'goods_paid', v_goods_paid::text,
      'other_paid', v_operating::text,
      'net_change', (v_income - v_goods_paid - v_operating)::text
    ),
    'stock_value', v_stock_value::text,
    'stock_value_date', to_char(v_stock_date, 'YYYY-MM-DD')
  );
end;
$$;

/**
 * S-16 cards. The owner's Troškovi are the cost of goods sold, Manjak robe (D-103) and
 * the operating expenses, so Profit is the statement's. A manager (D-80) receives
 * income and the expenses as paid, salaries left out; an adjustment is never paid, so a
 * manager's numbers do not change.
 */
create or replace function fin_summary(p_from date, p_to date)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
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

  -- D-77: salaries never reach a manager, not even inside a total.
  select coalesce(sum(e.amount), 0),
         coalesce(sum(e.amount) filter (where e.stock_movement_id is null), 0)
  into v_expenses, v_operating
  from expenses e
  join expense_categories c on c.id = e.category_id
  where e.gym_id = v_staff.gym_id and e.voided_at is null
    and e.spent_on between p_from and p_to
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

/**
 * S-16 chart (D-68): a year by months or a month by days, each slot with its income and
 * what it cost (D-92): operating expenses, the cost of the goods sold and, since D-103,
 * Manjak robe on the day the stock was counted. Its profit is the statement's.
 */
create or replace function fin_chart(p_year integer, p_month integer default null)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
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
    (select min(spent_on) from expenses
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
      -- BR-151 (D-92): operating expenses by the day they were spent; a stock-in's
      -- expense is not one.
      select date_trunc(v_unit, spent_on::timestamp)::date as slot, amount
      from expenses
      where gym_id = v_staff.gym_id and voided_at is null
        and spent_on between v_from and v_to
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

/**
 * S-20 (D-92): per product the prices, the period's stock-ins and sales with their cost,
 * profit and margin, and the stock and its value at the end of the period (BR-159).
 * D-103 adds each product's adjustments in the period (`adjust_quantity`, signed, and
 * `shrinkage`, the statement's Manjak robe) and the list of adjustments with [Poništi].
 */
create or replace function fin_storage(p_from date, p_to date)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_staff      staff := assert_owner();
  v_tz         text := (select timezone from gyms where id = v_staff.gym_id);
  -- D-90: the period as instants, measured once; see gym_day_start().
  v_start      timestamptz := gym_day_start(v_staff.gym_id, p_from);
  v_end        timestamptz := gym_day_start(v_staff.gym_id, p_to + 1);
  v_stock_date date := least(p_to, gym_today(v_staff.gym_id));
begin
  return (
    with per_product as (
      select p.id as product_id,
             p.name,
             p.current_purchase_price as purchase_price,
             p.sale_price,
             coalesce(came.quantity, 0) as in_quantity,
             coalesce(came.amount, 0) as in_amount,
             coalesce(sold.quantity, 0) as sold_quantity,
             coalesce(sold.revenue, 0) as revenue,
             coalesce(sold.cost, 0) as cost,
             coalesce(adjusted.quantity, 0) as adjust_quantity,
             coalesce(adjusted.shrinkage, 0) as shrinkage,
             at_end.stock,
             at_end.value as stock_value
      from products p
      join product_stock_at(v_staff.gym_id, v_stock_date) at_end
        on at_end.product_id = p.id
      left join lateral (
        select sum(quantity)::int as quantity,
               sum(quantity * unit_cost) as amount
        from stock_movements sm
        where sm.product_id = p.id and sm.type = 'in' and sm.voided_at is null
          and sm.created_at >= v_start and sm.created_at < v_end
      ) came on true
      left join lateral (
        select sum(quantity)::int as quantity,
               sum(quantity * unit_price) as revenue,
               sum(quantity * unit_cost) as cost
        from stock_movements sm
        where sm.product_id = p.id and sm.type = 'out' and sm.voided_at is null
          and sm.created_at >= v_start and sm.created_at < v_end
      ) sold on true
      left join lateral (
        select sum(quantity)::int as quantity,
               sum(-quantity * unit_cost) as shrinkage
        from stock_movements sm
        where sm.product_id = p.id and sm.type = 'adjust' and sm.voided_at is null
          and sm.created_at >= v_start and sm.created_at < v_end
      ) adjusted on true
      where p.gym_id = v_staff.gym_id
    )
    select json_build_object(
      'stock_date', to_char(v_stock_date, 'YYYY-MM-DD'),
      'products', coalesce((
        select json_agg(json_build_object(
                 'product_id', r.product_id,
                 'name', r.name,
                 'purchase_price', r.purchase_price::text,
                 'sale_price', r.sale_price::text,
                 'in_quantity', r.in_quantity,
                 'in_amount', r.in_amount::numeric(12,2)::text,
                 'sold_quantity', r.sold_quantity,
                 'revenue', r.revenue::numeric(12,2)::text,
                 'cost', r.cost::numeric(12,2)::text,
                 'profit', (r.revenue - r.cost)::numeric(12,2)::text,
                 'margin_pct', case when r.revenue > 0
                                    then round((r.revenue - r.cost) * 100 / r.revenue, 1)::text
                               end,
                 'adjust_quantity', r.adjust_quantity,
                 'shrinkage', r.shrinkage::numeric(12,2)::text,
                 'stock', r.stock,
                 'stock_value', r.stock_value::numeric(12,2)::text)
               order by r.name)
        from per_product r), '[]'::json),
      'totals', (
        select json_build_object(
                 'in_quantity', coalesce(sum(r.in_quantity), 0)::int,
                 'in_amount', coalesce(sum(r.in_amount), 0)::numeric(12,2)::text,
                 'sold_quantity', coalesce(sum(r.sold_quantity), 0)::int,
                 'revenue', coalesce(sum(r.revenue), 0)::numeric(12,2)::text,
                 'cost', coalesce(sum(r.cost), 0)::numeric(12,2)::text,
                 'profit', coalesce(sum(r.revenue - r.cost), 0)::numeric(12,2)::text,
                 'margin_pct', case when sum(r.revenue) > 0
                                    then round(sum(r.revenue - r.cost) * 100
                                               / sum(r.revenue), 1)::text
                               end,
                 'adjust_quantity', coalesce(sum(r.adjust_quantity), 0)::int,
                 'shrinkage', coalesce(sum(r.shrinkage), 0)::numeric(12,2)::text,
                 'stock', coalesce(sum(r.stock), 0)::int,
                 'stock_value', coalesce(sum(r.stock_value), 0)::numeric(12,2)::text)
        from per_product r),
      'daily', coalesce((
        select json_agg(row_to_json(t) order by t.day desc, t.name)
        from (
          select (sm.created_at at time zone v_tz)::date as day,
                 p.name,
                 sum(sm.quantity)::int as quantity,
                 sum(sm.quantity * sm.unit_price)::text as revenue
          from stock_movements sm join products p on p.id = sm.product_id
          where sm.gym_id = v_staff.gym_id and sm.type = 'out' and sm.voided_at is null
            and sm.created_at >= v_start and sm.created_at < v_end
          group by 1, 2
        ) t), '[]'::json),
      'stock_ins', coalesce((
        select json_agg(row_to_json(t) order by t.created_at desc)
        from (
          select sm.id,
                 sm.created_at,
                 p.name,
                 sm.quantity,
                 sm.unit_cost::text as unit_cost,
                 round(sm.quantity * sm.unit_cost, 2)::text as total,
                 sm.paid_from_till,
                 s.full_name as created_by_name,
                 sm.voided_at,
                 sm.void_reason
          from stock_movements sm
          join products p on p.id = sm.product_id
          join staff s on s.id = sm.created_by
          where sm.gym_id = v_staff.gym_id and sm.type = 'in'
            and sm.created_at >= v_start and sm.created_at < v_end
        ) t), '[]'::json),
      -- D-103: the adjustments of the period, voided ones included (BR-095).
      'adjustments', coalesce((
        select json_agg(row_to_json(t) order by t.created_at desc)
        from (
          select sm.id,
                 sm.created_at,
                 p.name,
                 sm.counted_qty - sm.quantity as before_qty,
                 sm.counted_qty,
                 sm.quantity,
                 sm.adjust_reason,
                 sm.note,
                 sm.unit_cost::text as unit_cost,
                 round(-sm.quantity * sm.unit_cost, 2)::text as shrinkage,
                 s.full_name as created_by_name,
                 sm.voided_at,
                 sm.void_reason
          from stock_movements sm
          join products p on p.id = sm.product_id
          join staff s on s.id = sm.created_by
          where sm.gym_id = v_staff.gym_id and sm.type = 'adjust'
            and sm.created_at >= v_start and sm.created_at < v_end
        ) t), '[]'::json)
    )
  );
end;
$$;

-- Function privileges ---------------------------------------------------------------------
-- Signed-in staff only; adjust_stock checks the role and the gym itself.
revoke execute on function adjust_stock(uuid, integer, integer, text, text) from public, anon;
