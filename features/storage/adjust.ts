import { me } from "@/lib/i18n/me";

/** D-103 (BR-145): the reasons adjust_stock accepts (migration 0054). */
export const ADJUST_REASONS = [
  "damaged",
  "expired",
  "internal_use",
  "count",
  "other",
] as const;

export type AdjustReason = (typeof ADJUST_REASONS)[number];

/**
 * BR-145: goods short may be damaged, expired or used up in the gym; a stock count and
 * Ostalo go either way, so goods found offer only those two.
 */
export function reasonsFor(difference: number): readonly AdjustReason[] {
  return difference > 0 ? ["count", "other"] : ADJUST_REASONS;
}

/** The reason as S-13 and S-20 name it; a count reads as Manjak or Višak pri popisu. */
export function adjustReasonLabel(reason: string, difference: number): string {
  const labels = me.storage.adjustReasons;
  if (reason === "count")
    return difference > 0 ? labels.countOver : labels.countShort;
  return labels[reason as keyof typeof labels] ?? reason;
}

/** A difference with its sign written out, as money is (formatMoney): +2, -5. */
export function signedQuantity(value: number): string {
  return value > 0 ? `+${value}` : String(value);
}
