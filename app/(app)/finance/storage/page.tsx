import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { PeriodPicker } from "@/features/finance/components/period-picker";
import {
  StorageReport,
  type AdjustmentRow,
  type DailyRow,
  type StockInRow,
  type StorageProductRow,
  type StorageTotals,
} from "@/features/finance/components/storage-report";
import { periodFromParams } from "@/features/finance/period";
import { requireStaff } from "@/lib/auth";
import { gymToday } from "@/lib/gym-date";
import { me } from "@/lib/i18n/me";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: `${me.finance.storageTitle} — ${me.app.name}`,
};

type Report = {
  /** D-92 (BR-159): the day the stock and its value are given for. */
  stock_date: string | null;
  products: StorageProductRow[];
  totals: StorageTotals | null;
  daily: DailyRow[];
  stock_ins: StockInRow[];
  /** D-103: the period's stock adjustments. */
  adjustments: AdjustmentRow[];
};

/**
 * S-20 (F-15 for the owner). The layout has already refused the receptionist; stock value
 * and bar profit stay the owner's and the admin's (BR-144, D-80), so a manager gets 404.
 */
export default async function StorageReportPage({
  searchParams,
}: {
  searchParams: Promise<{ period?: string; from?: string; to?: string }>;
}) {
  const staff = await requireStaff();
  if (staff.role !== "owner" && staff.role !== "admin") notFound();
  const period = periodFromParams(
    await searchParams,
    await gymToday(staff.gym_id),
  );

  const supabase = await createClient();
  const report = await supabase.rpc("fin_storage", {
    p_from: period.from,
    p_to: period.to,
  });
  const data = (report.data as Report | null) ?? {
    stock_date: null,
    products: [],
    totals: null,
    daily: [],
    stock_ins: [],
    adjustments: [],
  };

  // D-103: an adjustment whose product was counted again later, in this period or
  // after it. Voiding it would move the stock away from the latest count, so its void
  // dialog warns. The owner reads every stock movement of the gym (doc 07 §6).
  const open = data.adjustments.filter((row) => !row.voided_at);
  const recounted: string[] = [];
  if (open.length) {
    const oldest = open.reduce(
      (first, row) =>
        Date.parse(row.created_at) < Date.parse(first) ? row.created_at : first,
      open[0].created_at,
    );
    const { data: counts } = await supabase
      .from("stock_movements")
      .select("id, product_id, created_at")
      .eq("type", "adjust")
      .is("voided_at", null)
      .gte("created_at", oldest)
      .returns<{ id: string; product_id: string; created_at: string }[]>();
    for (const row of open) {
      const own = counts?.find((count) => count.id === row.id);
      if (
        own &&
        counts?.some(
          (count) =>
            count.product_id === own.product_id &&
            Date.parse(count.created_at) > Date.parse(own.created_at),
        )
      )
        recounted.push(row.id);
    }
  }

  return (
    <div className="grid grid-cols-1 gap-6">
      <PeriodPicker period={period} />
      <StorageReport
        products={data.products}
        totals={data.totals}
        stockDate={data.stock_date}
        daily={data.daily}
        stockIns={data.stock_ins}
        adjustments={data.adjustments}
        recounted={recounted}
      />
    </div>
  );
}
