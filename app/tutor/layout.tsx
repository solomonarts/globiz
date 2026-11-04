import type { ReactNode } from "react";
import { DashboardLayout } from "@/app/components/dashboard-layout";

export default function TutorLayout({ children }: { children: ReactNode }) {
  return <DashboardLayout role="tutor">{children}</DashboardLayout>;
}
