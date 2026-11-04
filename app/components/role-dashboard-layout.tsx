import type { ReactNode } from "react";
import { DashboardLayout } from "@/app/components/dashboard-layout";
import { getProfile } from "@/lib/auth";

export async function RoleDashboardLayout({ children }: { children: ReactNode }) {
  const profile = await getProfile();
  if (!profile) return children;
  return <DashboardLayout role={profile.role}>{children}</DashboardLayout>;
}
