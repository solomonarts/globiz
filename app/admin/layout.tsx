import type { ReactNode } from "react";
import { DashboardLayout } from "@/app/components/dashboard-layout";

export default function AdminLayout({ children }: { children: ReactNode }) {
  return <DashboardLayout role="admin">{children}</DashboardLayout>;
}
