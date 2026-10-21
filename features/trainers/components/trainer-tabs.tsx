import Link from "next/link";
import { me } from "@/lib/i18n/me";
import { cn } from "@/lib/utils";

const t = me.trainerRoster;

export type TrainerTab = "grupni" | "personalni";

/**
 * S-29 (D-72, D-105): the title, the tabs Grupni (`/trainers`) and Personalni
 * (`/trainers?tab=personalni`), and the line that says what the open tab lists.
 */
export function TrainerTabs({ tab }: { tab: TrainerTab }) {
  const tabs: { id: TrainerTab; label: string; href: string }[] = [
    { id: "grupni", label: t.tabGroup, href: "/trainers" },
    {
      id: "personalni",
      label: t.tabPersonal,
      href: "/trainers?tab=personalni",
    },
  ];

  return (
    <div>
      <h1 className="text-2xl font-semibold tracking-tight">{t.title}</h1>
      <nav
        aria-label={t.tabs}
        className="mt-4 flex gap-1 overflow-x-auto border-b"
      >
        {tabs.map((item) => (
          <Link
            key={item.id}
            href={item.href}
            prefetch={false}
            scroll={false}
            aria-current={tab === item.id ? "page" : undefined}
            className={cn(
              "-mb-px border-b-2 border-transparent px-3 py-2 text-sm font-medium whitespace-nowrap text-muted-foreground hover:text-foreground",
              tab === item.id && "border-primary text-foreground",
            )}
          >
            {item.label}
          </Link>
        ))}
      </nav>
      <p className="mt-3 text-sm text-muted-foreground">
        {tab === "personalni" ? t.personalIntro : t.intro}
      </p>
    </div>
  );
}
