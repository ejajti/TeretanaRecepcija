import { me } from "@/lib/i18n/me";

/** D-104 (BR-133): an expense is for the month it was paid or one of the 12 before it. */
export const COST_MONTHS_BACK = 12;

/** The 1st of the month of a yyyy-mm-dd date. */
export function monthOf(date: string): string {
  return `${date.slice(0, 7)}-01`;
}

/** The months an expense paid on `paidOn` may be for, the month paid first. */
export function costMonthOptions(paidOn: string): string[] {
  const year = Number(paidOn.slice(0, 4));
  const month = Number(paidOn.slice(5, 7)) - 1;
  return Array.from({ length: COST_MONTHS_BACK + 1 }, (_, back) =>
    new Date(Date.UTC(year, month - back, 1)).toISOString().slice(0, 10),
  );
}

/** A month as the screens name it: "septembar 2026". */
export function formatMonth(month: string): string {
  return `${me.finance.monthNames[Number(month.slice(5, 7)) - 1]} ${month.slice(0, 4)}`;
}
