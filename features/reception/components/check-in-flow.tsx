"use client";

import {
  useCallback,
  useEffect,
  useState,
  useTransition,
  type FormEvent,
  type ReactNode,
} from "react";
import { CircleAlert, CircleCheck, Loader2, TriangleAlert } from "lucide-react";
import { useAppState } from "@/components/common/app-state";
import { useToast } from "@/components/common/toast";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import type { SaleCheckIn } from "@/features/memberships/actions";
import type { SaleCatalog } from "@/features/memberships/catalog";
import { SellDialog } from "@/features/memberships/components/sell-dialog";
import { formatDate, formatDuration } from "@/lib/format";
import { me } from "@/lib/i18n/me";
import { playSound } from "@/lib/sounds";
import { cn } from "@/lib/utils";
import { checkIn, checkInUnpaid, checkOut } from "../actions";
import type {
  CheckInOptions,
  CheckInResult,
  MemberBrief,
  RenewQuestion,
  ScanOutcome,
  VisitType,
} from "../types";

type FlowState =
  | null
  | {
      kind: "choose";
      member: MemberBrief;
      manual: boolean;
      options: CheckInOptions;
    }
  | { kind: "renew"; question: RenewQuestion }
  | { kind: "result"; result: CheckInResult }
  | { kind: "confirm"; visitId: string; member: MemberBrief; seconds: number };

const fullName = (member: MemberBrief) =>
  `${member.first_name} ${member.last_name}`;

/**
 * The check-in and check-out dialogs of S-03 (S-03a to S-03f), shared by reception, the
 * member list (after "Prijavi odmah") and the profile ([Ručna prijava]).
 *
 * `handle` takes whatever a scan or a manual start answered and shows the right thing.
 * It returns false for the card messages (BR-070) that reception shows in its status
 * area instead of a dialog. `scanBlocked` is true while S-03a, S-03e or S-03f waits for
 * a decision, when a scan must not act behind the dialog.
 */
export function useCheckInFlow({
  catalog,
  onChanged,
}: {
  catalog: SaleCatalog;
  onChanged: () => void;
}) {
  const [state, setState] = useState<FlowState>(null);
  const [selling, setSelling] = useState<{
    memberId: string;
    defaults: CheckInResult["trainer_defaults"];
    /** D-109: from S-03f, which [Otkaži] on S-08 returns to. */
    renew?: RenewQuestion;
  } | null>(null);
  const toast = useToast();

  const handle = useCallback(
    (outcome: ScanOutcome): boolean => {
      // D-100 (BR-056): coming in ended the member's pause; the desk is told.
      if (
        (outcome.result === "checked_in" ||
          outcome.result === "choose" ||
          outcome.result === "renew") &&
        outcome.pause_ended
      )
        toast({ tone: "success", message: me.memberships.pauseEndedByVisit });
      switch (outcome.result) {
        case "checked_in": {
          const result = outcome.check_in;
          // BR-079: ok, warning or alarm, always with its dialog (D-47).
          playSound(
            result.covered
              ? "ok"
              : result.unpaid_count >= 2
                ? "alarm"
                : "warning",
          );
          setState({ kind: "result", result });
          onChanged();
          return true;
        }
        case "choose":
          setState({
            kind: "choose",
            member: outcome.member,
            manual: outcome.manual,
            options: outcome.options,
          });
          return true;
        case "renew":
          // D-109: S-03f, with the sound the unpaid visit would bring (BR-079).
          playSound(outcome.unpaid_count >= 1 ? "alarm" : "warning");
          setState({ kind: "renew", question: outcome });
          return true;
        case "confirm_checkout":
          setState({
            kind: "confirm",
            visitId: outcome.visit_id,
            member: outcome.member,
            // BR-072: a second desk's scan can start its transaction a moment before
            // the first desk's check-in, and would read "prije -1 s".
            seconds: Math.max(0, outcome.seconds),
          });
          return true;
        case "checked_out":
          // US-04.5 AC1: a toast with the name and the duration.
          setState(null);
          toast({
            tone: "success",
            message: me.reception.checkedOut
              .replace("{name}", fullName(outcome.member))
              .replace("{duration}", formatDuration(outcome.duration_seconds)),
          });
          onChanged();
          return true;
        default:
          return false;
      }
    },
    [onChanged, toast],
  );

  const close = useCallback(() => setState(null), []);

  // D-109: [Neplaćeni dolazak] needs no second dialog, S-03f has already warned.
  const recordedUnpaid = useCallback(
    (outcome: ScanOutcome) => {
      if (outcome.result === "checked_in" && !outcome.check_in.covered) {
        setState(null);
        toast({
          tone: "error",
          message: me.reception.unpaidRecorded.replace(
            "{name}",
            fullName(outcome.check_in.member),
          ),
        });
        onChanged();
        return;
      }
      handle(outcome);
    },
    [handle, onChanged, toast],
  );

  // D-109: the sale from S-03f checked the member in, or says why it did not.
  const sold = useCallback(
    (sale: SaleCheckIn) => {
      setSelling(null);
      onChanged();
      if (sale.checkIn) {
        handle({ result: "checked_in", check_in: sale.checkIn });
        return;
      }
      toast({
        tone: "error",
        message:
          sale.notCheckedIn === "inside"
            ? me.errors.E_MEMBER_HAS_OPEN_VISIT
            : sale.notCheckedIn === "no_class"
              ? me.members.notCheckedInNoClass
              : me.members.checkInNotToday,
      });
    },
    [handle, onChanged, toast],
  );

  const renewal = selling?.renew?.renewal ?? null;

  const element: ReactNode = (
    <>
      {state?.kind === "choose" ? (
        <VisitTypeDialog
          key={state.member.id}
          member={state.member}
          manual={state.manual}
          options={state.options}
          onCancel={close}
          onDone={handle}
        />
      ) : null}
      {state?.kind === "renew" ? (
        <RenewDialog
          key={state.question.member.id}
          question={state.question}
          onCancel={() => {
            // D-109: nothing was recorded, so the member scans again.
            toast({
              tone: "error",
              message: me.reception.notCheckedIn.replace(
                "{name}",
                fullName(state.question.member),
              ),
            });
            close();
          }}
          onRenew={() => {
            setSelling({
              memberId: state.question.member.id,
              defaults: state.question.trainer_defaults,
              renew: state.question,
            });
            close();
          }}
          onUnpaid={recordedUnpaid}
        />
      ) : null}
      {state?.kind === "confirm" ? (
        <ConfirmCheckOutDialog
          visitId={state.visitId}
          member={state.member}
          seconds={state.seconds}
          onCancel={close}
          onDone={handle}
        />
      ) : null}
      {state?.kind === "result" ? (
        <ResultDialog
          key={state.result.visit_id}
          result={state.result}
          onClose={close}
          onRenew={() => {
            setSelling({
              memberId: state.result.member.id,
              defaults: state.result.trainer_defaults,
            });
            close();
          }}
        />
      ) : null}
      {/* US-04.4 AC2: [Produži članarinu] opens S-08 for that member; from S-03f
          (D-109) with the membership to renew preselected, checking the member in. */}
      <SellDialog
        open={selling !== null}
        onOpenChange={(open) => {
          if (!open) {
            const question = selling?.renew;
            setSelling(null);
            onChanged();
            if (question) setState({ kind: "renew", question });
          }
        }}
        memberId={selling?.memberId ?? ""}
        catalog={catalog}
        defaultPlanId={renewal?.plan_id}
        trainerDefaults={{
          group: selling?.defaults.group ?? undefined,
          personal: selling?.defaults.personal ?? undefined,
        }}
        classTimeDefaults={
          renewal?.trainer_id && renewal.class_time
            ? { [renewal.trainer_id]: renewal.class_time }
            : undefined
        }
        checkIn={selling?.renew ? { manual: selling.renew.manual } : undefined}
        onSold={selling?.renew ? sold : undefined}
      />
    </>
  );

  return {
    handle,
    element,
    scanBlocked:
      state?.kind === "choose" ||
      state?.kind === "confirm" ||
      state?.kind === "renew" ||
      selling !== null,
  };
}

/** Runs an action and reports a lost connection to the F-27 banner. */
function useRunner() {
  const { reportNetworkFailure, reportNetworkSuccess } = useAppState();
  const toast = useToast();
  const [pending, start] = useTransition();
  const run = useCallback(
    (
      work: () => Promise<
        { ok: true; data: ScanOutcome } | { ok: false; error: string }
      >,
      done: (outcome: ScanOutcome) => void,
    ) =>
      start(async () => {
        try {
          const answer = await work();
          reportNetworkSuccess();
          if (answer.ok) done(answer.data);
          else toast({ tone: "error", message: answer.error });
        } catch {
          reportNetworkFailure();
          toast({ tone: "error", message: me.errors.unexpected });
        }
      }),
    [reportNetworkFailure, reportNetworkSuccess, toast],
  );
  return [pending, run] as const;
}

/**
 * S-03a (BR-073 to BR-076): the type, then the trainer and class where they apply, and
 * the membership when two or more cover the type. Enter confirms, Esc cancels and
 * nothing is saved (US-04.3 AC2).
 */
function VisitTypeDialog({
  member,
  manual,
  options,
  onCancel,
  onDone,
}: {
  member: MemberBrief;
  manual: boolean;
  options: CheckInOptions;
  onCancel: () => void;
  onDone: (outcome: ScanOutcome) => void;
}) {
  const [type, setType] = useState<VisitType>(options.preselect);
  const candidates = options.candidates[type] ?? [];
  const [membershipId, setMembershipId] = useState(candidates[0]?.id ?? "");
  const defaultTrainer = useCallback(
    (forType: VisitType, candidateId: string): string => {
      if (forType === "gym") return "";
      const list =
        forType === "group"
          ? options.group_trainers
          : options.personal_trainers;
      const candidate = (options.candidates[forType] ?? []).find(
        (item) => item.id === candidateId,
      );
      // BR-075/076: the membership's trainer; for an unpaid group visit, the trainer of
      // the latest group or combo membership; otherwise nobody.
      const preferred =
        candidate?.trainer_id ??
        (forType === "group" && !candidate
          ? options.fallback_group_trainer
          : null);
      return preferred && list.some((trainer) => trainer.id === preferred)
        ? preferred
        : "";
    },
    [options],
  );
  const defaultSlot = useCallback(
    (trainer: string) =>
      options.group_trainers.find((item) => item.id === trainer)
        ?.default_slot ?? "",
    [options],
  );
  const [trainerId, setTrainerId] = useState(() =>
    defaultTrainer(options.preselect, candidates[0]?.id ?? ""),
  );
  const [slotId, setSlotId] = useState(() => defaultSlot(trainerId));
  const [pending, run] = useRunner();

  function chooseType(next: VisitType) {
    const first = options.candidates[next]?.[0]?.id ?? "";
    const trainer = defaultTrainer(next, first);
    setType(next);
    setMembershipId(first);
    setTrainerId(trainer);
    setSlotId(next === "group" ? defaultSlot(trainer) : "");
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    run(
      () =>
        checkIn({
          memberId: member.id,
          type,
          membershipId: membershipId || null,
          trainerId: trainerId || null,
          slotId: slotId || null,
          manual,
        }),
      onDone,
    );
  }

  const trainers =
    type === "group"
      ? options.group_trainers
      : type === "personal"
        ? options.personal_trainers
        : [];
  const slots = options.slots.filter((slot) => slot.trainer_id === trainerId);

  return (
    <Dialog open onOpenChange={(open) => !open && onCancel()}>
      <DialogContent aria-describedby={undefined}>
        <DialogHeader>
          <DialogTitle>
            {me.reception.checkInTitle.replace("{name}", fullName(member))}
          </DialogTitle>
        </DialogHeader>
        <form onSubmit={submit} className="grid gap-4">
          <fieldset className="grid gap-2">
            <legend className="mb-2 text-sm font-medium">
              {me.reception.visitType}
            </legend>
            <div className="grid grid-cols-3 gap-2" role="radiogroup">
              {options.types.map((option) => (
                <label
                  key={option}
                  className={cn(
                    "flex h-12 cursor-pointer items-center justify-center rounded-lg border bg-card text-sm font-medium has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring",
                    type === option &&
                      "border-primary bg-primary text-primary-foreground",
                  )}
                >
                  <input
                    type="radio"
                    name="visitType"
                    value={option}
                    checked={type === option}
                    onChange={() => chooseType(option)}
                    className="sr-only"
                  />
                  {me.visitTypes[option]}
                </label>
              ))}
            </div>
          </fieldset>

          {candidates.length >= 2 ? (
            <div className="grid gap-2">
              <Label htmlFor="checkin-membership">
                {me.reception.membership}
              </Label>
              <Select
                id="checkin-membership"
                value={membershipId}
                onChange={(event) => {
                  setMembershipId(event.target.value);
                  const trainer = defaultTrainer(type, event.target.value);
                  setTrainerId(trainer);
                  if (type === "group") setSlotId(defaultSlot(trainer));
                }}
              >
                {candidates.map((candidate) => (
                  <option key={candidate.id} value={candidate.id}>
                    {candidate.plan_name} · {me.reception.validUntil}{" "}
                    {formatDate(candidate.end_date)}
                  </option>
                ))}
              </Select>
            </div>
          ) : null}

          {type !== "gym" ? (
            <div className="grid gap-2">
              <Label htmlFor="checkin-trainer">{me.reception.trainer}</Label>
              <Select
                id="checkin-trainer"
                value={trainerId}
                required
                onChange={(event) => {
                  setTrainerId(event.target.value);
                  if (type === "group")
                    setSlotId(defaultSlot(event.target.value));
                }}
              >
                <option value="" disabled>
                  {me.memberships.trainerPlaceholder}
                </option>
                {trainers.map((trainer) => (
                  <option key={trainer.id} value={trainer.id}>
                    {trainer.full_name}
                  </option>
                ))}
              </Select>
            </div>
          ) : null}

          {type === "group" ? (
            <div className="grid gap-2">
              <Label htmlFor="checkin-slot">{me.reception.slot}</Label>
              <Select
                id="checkin-slot"
                value={slotId}
                onChange={(event) => setSlotId(event.target.value)}
              >
                <option value="">{me.reception.noSlot}</option>
                {slots.map((slot) => (
                  <option key={slot.id} value={slot.id}>
                    {me.reception.slotAt.replace("{time}", slot.starts_at)}
                  </option>
                ))}
              </Select>
            </div>
          ) : null}

          <DialogFooter>
            <DialogClose asChild>
              <Button type="button" variant="outline">
                {me.common.cancel}
              </Button>
            </DialogClose>
            <Button
              type="submit"
              autoFocus
              disabled={pending || (type !== "gym" && !trainerId)}
            >
              {pending ? (
                <Loader2 aria-hidden="true" className="animate-spin" />
              ) : null}
              {me.reception.checkIn}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

/**
 * S-03f (D-109): an expired or used-up membership. Nothing is recorded until the desk
 * chooses: [Produži članarinu] sells and checks in, [Neplaćeni dolazak] records the
 * unpaid visit, [Otkaži] (or Esc) records nothing. Yellow, or full-screen red when the
 * member already has an unpaid visit, as the visit would be (BR-079).
 */
function RenewDialog({
  question,
  onCancel,
  onRenew,
  onUnpaid,
}: {
  question: RenewQuestion;
  onCancel: () => void;
  onRenew: () => void;
  onUnpaid: (outcome: ScanOutcome) => void;
}) {
  const [pending, run] = useRunner();
  const red = question.unpaid_count >= 1;
  const plan = question.plan_name ?? "";
  const reason =
    question.reason === "expired"
      ? me.reception.renewExpired
          .replace("{plan}", plan)
          .replace(
            "{date}",
            question.end_date ? formatDate(question.end_date) : "",
          )
      : question.reason === "used_up"
        ? me.reception.renewUsedUp.replace("{plan}", plan)
        : me.reception.renewNone;
  return (
    <Dialog open onOpenChange={(open) => !open && onCancel()}>
      <DialogContent
        data-result={red ? "renew-red" : "renew-yellow"}
        className={cn(
          red
            ? "top-0 left-0 flex h-svh w-screen max-w-none translate-x-0 translate-y-0 flex-col items-center justify-center gap-8 rounded-none border-0 bg-danger text-center text-white"
            : "border-4 border-amber-500 bg-amber-50",
        )}
      >
        <DialogHeader className={cn(red && "items-center")}>
          <DialogTitle
            className={cn("flex items-center gap-2", red && "text-2xl")}
          >
            {red ? (
              <CircleAlert aria-hidden="true" className="size-8" />
            ) : (
              <TriangleAlert
                aria-hidden="true"
                className="size-6 text-amber-700"
              />
            )}
            {`${fullName(question.member)} (#${question.member.member_number})`}
          </DialogTitle>
          <DialogDescription
            className={cn(
              "grid gap-2",
              red
                ? "text-xl font-medium text-white"
                : "text-base font-medium text-foreground",
            )}
          >
            <span>{reason}</span>
            {red ? (
              <span className="text-5xl leading-tight font-bold">
                {me.reception.renewUnpaid.replace(
                  "{count}",
                  String(question.unpaid_count),
                )}
              </span>
            ) : null}
            <span>{me.reception.renewQuestion}</span>
          </DialogDescription>
        </DialogHeader>
        <DialogFooter className={cn(red && "gap-4 sm:justify-center")}>
          <Button
            type="button"
            autoFocus
            variant={red ? "outline" : "default"}
            className={cn(
              red && "h-14 border-white bg-white px-8 text-lg text-danger",
            )}
            disabled={pending}
            onClick={onRenew}
          >
            {me.reception.renew}
          </Button>
          <Button
            type="button"
            variant="outline"
            className={cn(
              red &&
                "h-14 border-white bg-transparent px-8 text-lg text-white hover:bg-white/10",
            )}
            disabled={pending}
            onClick={() =>
              run(
                () => checkInUnpaid(question.member.id, question.manual),
                onUnpaid,
              )
            }
          >
            {pending ? (
              <Loader2 aria-hidden="true" className="animate-spin" />
            ) : null}
            {me.reception.unpaidVisit}
          </Button>
          <DialogClose asChild>
            <Button
              type="button"
              variant="ghost"
              className={cn(
                red &&
                  "h-14 px-8 text-lg text-white hover:bg-white/10 hover:text-white",
              )}
              disabled={pending}
            >
              {me.common.cancel}
            </Button>
          </DialogClose>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** S-03e (BR-072): a second scan within the guard time asks before checking out. */
function ConfirmCheckOutDialog({
  visitId,
  member,
  seconds,
  onCancel,
  onDone,
}: {
  visitId: string;
  member: MemberBrief;
  seconds: number;
  onCancel: () => void;
  onDone: (outcome: ScanOutcome) => void;
}) {
  const [pending, run] = useRunner();
  return (
    <Dialog open onOpenChange={(open) => !open && onCancel()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{me.reception.checkOut}</DialogTitle>
          <DialogDescription className="text-base">
            {me.reception.confirmCheckout
              .replace("{name}", fullName(member))
              .replace("{seconds}", String(seconds))}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <DialogClose asChild>
            <Button type="button" variant="outline">
              {me.reception.no}
            </Button>
          </DialogClose>
          <Button
            type="button"
            autoFocus
            disabled={pending}
            onClick={() => run(() => checkOut(visitId, true), onDone)}
          >
            {me.reception.checkOut}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/**
 * BR-079: green when covered (closes after 5 s, AS-13), yellow for the first unpaid
 * visit, full-screen red from the second. The unpaid ones never close by themselves.
 */
function ResultDialog({
  result,
  onClose,
  onRenew,
}: {
  result: CheckInResult;
  onClose: () => void;
  onRenew: () => void;
}) {
  const name = `${fullName(result.member)} (#${result.member.member_number})`;
  useEffect(() => {
    if (!result.covered) return;
    const timer = setTimeout(onClose, 5000);
    return () => clearTimeout(timer);
  }, [result, onClose]);

  if (result.covered) {
    const remaining =
      result.remaining === null
        ? me.members.unlimited
        : me.members.remaining
            .replace("{type}", me.visitTypes[result.visit_type])
            .replace("{count}", String(Math.max(result.remaining, 0)));
    return (
      <Dialog open onOpenChange={(open) => !open && onClose()}>
        <DialogContent
          className="border-success border-4"
          data-result="covered"
        >
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2 text-success">
              <CircleCheck aria-hidden="true" className="size-6" />
              {name}
            </DialogTitle>
          </DialogHeader>
          {/* The details are the dialog's description, so Radix names them. */}
          <DialogDescription asChild>
            <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-base">
              <dt className="text-muted-foreground">
                {me.reception.membership}
              </dt>
              <dd className="font-medium">{result.plan_name}</dd>
              <dt className="text-muted-foreground">
                {me.reception.validUntil}
              </dt>
              <dd>{result.end_date ? formatDate(result.end_date) : "—"}</dd>
              <dt className="text-muted-foreground">
                {me.reception.remaining}
              </dt>
              <dd>{remaining}</dd>
              <dt className="text-muted-foreground">{me.reception.status}</dt>
              <dd>
                {result.status ? me.memberships.status[result.status] : "—"}
              </dd>
            </dl>
          </DialogDescription>
        </DialogContent>
      </Dialog>
    );
  }

  const red = result.unpaid_count >= 2;
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent
        data-result={red ? "red" : "yellow"}
        className={cn(
          red
            ? "top-0 left-0 flex h-svh w-screen max-w-none translate-x-0 translate-y-0 flex-col items-center justify-center gap-8 rounded-none border-0 bg-danger text-center text-white"
            : "border-4 border-amber-500 bg-amber-50",
        )}
      >
        <DialogHeader className={cn(red && "items-center")}>
          <DialogTitle
            className={cn("flex items-center gap-2", red && "text-2xl")}
          >
            {red ? (
              <CircleAlert aria-hidden="true" className="size-8" />
            ) : (
              <TriangleAlert
                aria-hidden="true"
                className="size-6 text-amber-700"
              />
            )}
            {name}
          </DialogTitle>
          <DialogDescription
            className={cn(
              red
                ? "text-5xl leading-tight font-bold text-white"
                : "text-base font-medium text-foreground",
            )}
          >
            {red
              ? me.reception.unpaidRed.replace(
                  "{count}",
                  String(result.unpaid_count),
                )
              : me.reception.unpaidYellow}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter className={cn(red && "gap-4 sm:justify-center")}>
          <Button
            type="button"
            size={red ? "default" : "default"}
            variant={red ? "outline" : "default"}
            className={cn(
              red && "h-14 border-white bg-white px-8 text-lg text-danger",
            )}
            onClick={onRenew}
          >
            {me.reception.renew}
          </Button>
          <Button
            type="button"
            variant="outline"
            className={cn(
              red &&
                "h-14 border-white bg-transparent px-8 text-lg text-white hover:bg-white/10",
            )}
            onClick={onClose}
          >
            {me.common.close}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
