import type { ReactNode } from "react";
import { DashboardLayout } from "@/app/components/dashboard-layout";

export default function LearningLayout({ children }: { children: ReactNode }) {
  return <DashboardLayout role="student">{children}</DashboardLayout>;
}
