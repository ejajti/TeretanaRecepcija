import { describe, expect, it } from "vitest";
import {
  limitedSessions,
  sessionsLeft,
  sessionsLeftMin,
  sessionsPreview,
  unpaidInPeriod,
  type SessionMembership,
} from "@/features/memberships/sessions";
import { sessionsChangeSchema } from "@/features/memberships/schemas";

// D-111 (BR-055a): S-07 [Izmijeni broj termina] — which types can change, the fewest
// that can be left, and what the dialog says added sessions will link.
const mjesecna12: SessionMembership = {
  start_date: "2026-10-10",
  end_date: "2026-11-10",
  covers_gym: true,
  covers_group: false,
  covers_personal: false,
  gym_visit_limit: 12,
  gym_used: 12,
  group_session_limit: null,
  group_used: 0,
  personal_session_limit: null,
  personal_used: 0,
  pauses: [],
};

const gt: SessionMembership = {
  ...mjesecna12,
  covers_group: true,
  gym_visit_limit: null,
  gym_used: 20,
  group_session_limit: 12,
  group_used: 4,
};

describe("D-111 limitedSessions", () => {
  it("lists only covered types with a limit", () => {
    expect(limitedSessions(mjesecna12)).toEqual([
      { type: "gym", limit: 12, used: 12 },
    ]);
    // G+T: the gym part is Neograničeno, so only the group sessions change.
    expect(limitedSessions(gt)).toEqual([
      { type: "group", limit: 12, used: 4 },
    ]);
    expect(limitedSessions({ ...mjesecna12, gym_visit_limit: null })).toEqual(
      [],
    );
  });

  it("BR-055: sessions left never go below 0", () => {
    expect(sessionsLeft({ type: "gym", limit: 12, used: 13 })).toBe(0);
    expect(sessionsLeft({ type: "group", limit: 12, used: 4 })).toBe(8);
  });

  it("BR-055a: at least 1 left while none is used, otherwise 0", () => {
    expect(sessionsLeftMin({ type: "personal", limit: 10, used: 0 })).toBe(1);
    expect(sessionsLeftMin({ type: "gym", limit: 12, used: 12 })).toBe(0);
  });
});

describe("D-111 unpaidInPeriod", () => {
  const visits = [
    { checked_in_at: "2026-10-09T09:00:00Z", visit_type: "gym" }, // before the start
    { checked_in_at: "2026-10-25T09:00:00Z", visit_type: "gym" },
    { checked_in_at: "2026-10-27T09:00:00Z", visit_type: "gym" },
    { checked_in_at: "2026-10-27T17:00:00Z", visit_type: "group" },
    // 10.11 at 23:30 UTC is already 11.11 in Podgorica, after the last day.
    { checked_in_at: "2026-11-10T23:30:00Z", visit_type: "gym" },
  ];

  it("counts the type's visits on the membership's days, by gym date", () => {
    expect(unpaidInPeriod(mjesecna12, visits, "gym")).toBe(2);
    expect(unpaidInPeriod(mjesecna12, visits, "group")).toBe(1);
  });

  it("BR-053: a paused day covers nothing, so its visit is not counted", () => {
    const paused = {
      ...mjesecna12,
      pauses: [{ paused_from: "2026-10-27", paused_until: "2026-10-28" }],
    };
    expect(unpaidInPeriod(paused, visits, "gym")).toBe(1);
  });
});

describe("D-111 sessionsPreview", () => {
  const usedUp = { type: "gym" as const, limit: 12, used: 12 };

  it("added sessions link the unpaid visits first, at most as many as are left", () => {
    expect(sessionsPreview(usedUp, 2, 2)).toEqual({
      total: 14,
      linked: 2,
      leftAfter: 0,
    });
    expect(sessionsPreview(usedUp, 3, 2)).toEqual({
      total: 15,
      linked: 2,
      leftAfter: 1,
    });
    expect(sessionsPreview(usedUp, 1, 2)).toEqual({
      total: 13,
      linked: 1,
      leftAfter: 0,
    });
  });

  it("the same or fewer sessions link nothing", () => {
    const some = { type: "group" as const, limit: 12, used: 4 };
    expect(sessionsPreview(some, 8, 3)).toEqual({
      total: 12,
      linked: 0,
      leftAfter: 8,
    });
    expect(sessionsPreview(some, 2, 3)).toEqual({
      total: 6,
      linked: 0,
      leftAfter: 2,
    });
  });
});

describe("D-111 sessionsChangeSchema", () => {
  const base = {
    memberId: "11111111-1111-4111-8111-111111111111",
    membershipId: "22222222-2222-4222-8222-222222222222",
  };

  it("takes 0 to 99 per type, empty as unchanged", () => {
    const parsed = sessionsChangeSchema.safeParse({
      ...base,
      gymLeft: "3",
      groupLeft: "",
    });
    expect(parsed.success && parsed.data).toMatchObject({
      gymLeft: 3,
      groupLeft: null,
      personalLeft: null,
    });
  });

  it("refuses out-of-range numbers and a form with no type", () => {
    for (const gymLeft of ["-1", "100", "2.5", "x"])
      expect(sessionsChangeSchema.safeParse({ ...base, gymLeft }).success).toBe(
        false,
      );
    expect(sessionsChangeSchema.safeParse(base).success).toBe(false);
  });
});
