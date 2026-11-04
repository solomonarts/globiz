import type { ReactNode } from "react";
import { DashboardLayout } from "@/app/components/dashboard-layout";

export default function CustomerLayout({ children }: { children: ReactNode }) {
  return <DashboardLayout role="customer">{children}</DashboardLayout>;
}
