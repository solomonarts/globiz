import type { ReactNode } from "react";
import { DashboardLayout } from "@/app/components/dashboard-layout";

export default function ProfessionalLayout({ children }: { children: ReactNode }) {
  return <DashboardLayout role="professional">{children}</DashboardLayout>;
}
