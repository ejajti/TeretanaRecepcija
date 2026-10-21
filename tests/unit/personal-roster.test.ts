import { describe, expect, it } from "vitest";
import {
  buildPersonalRoster,
  type PersonalRosterData,
  type PersonalRosterMember,
} from "@/features/trainers/personal-roster";

const julija = "11111111-1111-4111-8111-111111111111";
const tamara = "22222222-2222-4222-8222-222222222222";
const stara = "33333333-3333-4333-8333-333333333333";

function member(
  id: string,
  trainerId: string,
  trainerName: string,
  memberId: string,
  { start = "2026-10-01", limit = 12 as number | null, used = 0 } = {},
): PersonalRosterMember {
  return {
    membership_id: `ms-${id}`,
    trainer_id: trainerId,
    trainer_name: trainerName,
    member_id: `m-${memberId}`,
    member_number: Number(memberId),
    first_name: "Ime",
    last_name: memberId,
    plan_name: "Personalni",
    paid_on: "2026-10-01",
    start_date: start,
    end_date: "2026-10-31",
    personal_session_limit: limit,
    personal_used: used,
  };
}

// Wednesday 21.10.2026: Tamara and Julija train Personalni; Stara no longer does.
const data: PersonalRosterData = {
  today: "2026-10-21",
  trainers: [
    { trainer_id: julija, trainer_name: "Julija" },
    { trainer_id: tamara, trainer_name: "Tamara" },
  ],
  members: [
    member("1", julija, "Julija", "1", { used: 2 }),
    member("1b", julija, "Julija", "1", { start: "2026-11-01", limit: 8 }),
    member("2", julija, "Julija", "2", { limit: 4, used: 6 }),
    member("3", stara, "Stara", "3", { limit: null }),
  ],
};

describe("personal roster (D-105, BR-027a)", () => {
  it("lists every personal trainer by name, with no members as well", () => {
    const roster = buildPersonalRoster(data);
    expect(roster.map((trainer) => trainer.trainerName)).toEqual([
      "Julija",
      "Stara",
      "Tamara",
    ]);
    expect(roster[2]).toMatchObject({ rows: [], memberCount: 0 });
  });

  it("keeps a trainer who no longer trains Personalni with their members", () => {
    const stary = buildPersonalRoster(data).find(
      (trainer) => trainer.trainerId === stara,
    );
    expect(stary?.rows.map((row) => row.membership_id)).toEqual(["ms-3"]);
  });

  it("keeps one row per membership and counts each member once", () => {
    const [first] = buildPersonalRoster(data);
    expect(first.rows.map((row) => row.membership_id)).toEqual([
      "ms-1",
      "ms-1b",
      "ms-2",
    ]);
    expect(first.memberCount).toBe(2);
  });

  it("marks a membership that starts after today", () => {
    const [first] = buildPersonalRoster(data);
    expect(first.rows.map((row) => row.upcoming)).toEqual([false, true, false]);
  });

  it("counts the sessions left, never below 0, and null as unlimited", () => {
    const roster = buildPersonalRoster(data);
    expect(roster[0].rows.map((row) => row.left)).toEqual([10, 8, 0]);
    expect(roster[1].rows[0].left).toBeNull();
  });

  it("gives amounts and a total only when the prices are passed (BR-157)", () => {
    expect(
      buildPersonalRoster(data).every(
        (trainer) =>
          trainer.total === null &&
          trainer.rows.every((row) => row.amount === null),
      ),
    ).toBe(true);

    const prices = new Map([
      ["ms-1", "80.00"],
      ["ms-1b", "100.00"],
      ["ms-2", "45.50"],
    ]);
    const roster = buildPersonalRoster(data, prices);
    expect(roster[0].rows.map((row) => row.amount)).toEqual([
      "80.00",
      "100.00",
      "45.50",
    ]);
    expect(roster[0].total).toBe("225.50");
    // A membership with no amount adds nothing; a trainer with none totals 0.
    expect(roster[1].total).toBe("0.00");
    expect(roster[2].total).toBe("0.00");
  });
});
