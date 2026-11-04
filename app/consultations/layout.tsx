import type { ReactNode } from "react";
import { RoleDashboardLayout } from "@/app/components/role-dashboard-layout";

export default function ConsultationsLayout({ children }: { children: ReactNode }) {
  return <RoleDashboardLayout>{children}</RoleDashboardLayout>;
}
