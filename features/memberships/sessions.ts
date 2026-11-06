import { gymDateOf } from "@/lib/format";

/** D-111 (BR-055a): the visit types that can have a session limit. */
export type SessionType = "gym" | "group" | "personal";

/** BR-055a: the most sessions that can be left after a change. */
export const SESSIONS_LEFT_MAX = 99;

/** The membership columns the session change reads, as `member_memberships` returns them. */
export type SessionMembership = {
  start_date: string;
  end_date: string;
  covers_gym: boolean;
  covers_group: boolean;
  covers_personal: boolean;
  gym_visit_limit: number | null;
  gym_used: number;
  group_session_limit: number | null;
  group_used: number;
  personal_session_limit: number | null;
  personal_used: number;
  pauses: { paused_from: string; paused_until: string }[];
};

/** An unlinked unpaid visit of the member (US-10.1). */
export type UnpaidVisit = { checked_in_at: string; visit_type: string };

export type SessionCount = { type: SessionType; limit: number; used: number };

/** BR-055: the covered types with a limit, each with its limit and the sessions used. */
export function limitedSessions(membership: SessionMembership): SessionCount[] {
  const rows: [SessionType, boolean, number | null, number][] = [
    [
      "gym",
      membership.covers_gym,
      membership.gym_visit_limit,
      membership.gym_used,
    ],
    [
      "group",
      membership.covers_group,
      membership.group_session_limit,
      membership.group_used,
    ],
    [
      "personal",
      membership.covers_personal,
      membership.personal_session_limit,
      membership.personal_used,
    ],
  ];
  return rows
    .filter(([, covers, limit]) => covers && limit !== null)
    .map(([type, , limit, used]) => ({ type, limit: limit ?? 0, used }));
}

/** BR-055: sessions left, never below 0. */
export function sessionsLeft(count: SessionCount): number {
  return Math.max(count.limit - count.used, 0);
}

/** BR-055a: the fewest that can be left; a membership never holds 0 sessions in total. */
export function sessionsLeftMin(count: SessionCount): number {
  return count.used === 0 ? 1 : 0;
}

/**
 * BR-055a: the member's unlinked unpaid visits of `type` on the membership's days that are
 * not paused (BR-053), i.e. those that added sessions would link, oldest first in the RPC.
 */
export function unpaidInPeriod(
  membership: SessionMembership,
  visits: UnpaidVisit[],
  type: SessionType,
): number {
  return visits.filter((visit) => {
    if (visit.visit_type !== type) return false;
    const day = gymDateOf(visit.checked_in_at);
    if (day < membership.start_date || day > membership.end_date) return false;
    return !membership.pauses.some(
      (pause) => pause.paused_from <= day && day <= pause.paused_until,
    );
  }).length;
}

/**
 * BR-055a: what typing `left` does: the new total, and when sessions are added, how many
 * unpaid visits they link (at most `left`) and how many are left after that.
 */
export function sessionsPreview(
  count: SessionCount,
  left: number,
  unpaid: number,
): { total: number; linked: number; leftAfter: number } {
  const total = count.used + left;
  const linked = total > count.limit ? Math.min(unpaid, left) : 0;
  return { total, linked, leftAfter: left - linked };
}
