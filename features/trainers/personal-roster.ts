import { sumMoney } from "@/lib/format";

/** BR-023: an active trainer of an active personal program, as personal_roster() returns it. */
export type PersonalRosterTrainer = {
  trainer_id: string;
  trainer_name: string;
};

/** BR-027a: a personal membership that is valid today or starts later. */
export type PersonalRosterMember = {
  membership_id: string;
  trainer_id: string;
  trainer_name: string;
  member_id: string;
  member_number: number;
  first_name: string;
  last_name: string;
  plan_name: string;
  paid_on: string | null;
  start_date: string;
  end_date: string;
  /** Null is unlimited. */
  personal_session_limit: number | null;
  /** The personal visits counted on the membership (BR-054). */
  personal_used: number;
};

export type PersonalRosterData = {
  today: string;
  trainers: PersonalRosterTrainer[];
  members: PersonalRosterMember[];
};

export type PersonalRosterRow = PersonalRosterMember & {
  /** True when the membership starts after gym today. */
  upcoming: boolean;
  /** The sessions left, never below 0; null is unlimited. */
  left: number | null;
  /** BR-157: the owner's and admin's only; null for everyone else. */
  amount: string | null;
};

export type PersonalRosterGroup = {
  trainerId: string;
  trainerName: string;
  rows: PersonalRosterRow[];
  /** The members listed, each once even with a current and a next membership. */
  memberCount: number;
  /** BR-027a: the sum of the amounts, when they were given (owner and admin). */
  total: string | null;
};

/**
 * BR-027a: the personal roster by trainer. Every trainer of an active personal program is
 * kept, even with no members; a trainer who no longer is keeps their members. The rows
 * keep the order personal_roster() gives them (by member, the current membership first).
 * `prices` maps membership ids to their amounts and is passed only for the owner and admin.
 */
export function buildPersonalRoster(
  data: PersonalRosterData,
  prices?: ReadonlyMap<string, string>,
): PersonalRosterGroup[] {
  const trainers = new Map<
    string,
    { name: string; rows: PersonalRosterRow[] }
  >();
  const trainerFor = (trainerId: string, trainerName: string) => {
    const trainer = trainers.get(trainerId) ?? { name: trainerName, rows: [] };
    trainers.set(trainerId, trainer);
    return trainer;
  };

  for (const trainer of data.trainers)
    trainerFor(trainer.trainer_id, trainer.trainer_name);
  for (const member of data.members) {
    const limit = member.personal_session_limit;
    trainerFor(member.trainer_id, member.trainer_name).rows.push({
      ...member,
      upcoming: member.start_date > data.today,
      left: limit === null ? null : Math.max(limit - member.personal_used, 0),
      amount: prices?.get(member.membership_id) ?? null,
    });
  }

  return [...trainers.entries()]
    .map(([trainerId, trainer]) => ({
      trainerId,
      trainerName: trainer.name,
      rows: trainer.rows,
      memberCount: new Set(trainer.rows.map((row) => row.member_id)).size,
      total: prices
        ? sumMoney(
            trainer.rows.flatMap((row) => (row.amount ? [row.amount] : [])),
          )
        : null,
    }))
    .sort(
      (a, b) =>
        a.trainerName.localeCompare(b.trainerName, "sr-Latn") ||
        a.trainerId.localeCompare(b.trainerId),
    );
}
