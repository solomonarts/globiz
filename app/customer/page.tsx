import Link from "next/link";
import { redirect } from "next/navigation";
import { BriefcaseBusiness, CalendarDays, MessageSquareText } from "lucide-react";
import { DashboardLayout } from "@/app/components/dashboard-layout";
import { getProfile } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export default async function CustomerDashboard() {
  const profile = await getProfile();
  if (!profile) redirect("/login");
  if (profile.account_status !== "active") redirect("/account/status");
  if (profile.role !== "customer") redirect(`/${profile.role}`);

  const supabase = await createClient();
  const { count } = supabase
    ? await supabase.from("bookings").select("id", { count: "exact", head: true }).eq("customer_id", profile.id)
    : { count: null };

  return <DashboardLayout role="customer"><main className="customer-dashboard">
    <span className="pill">CUSTOMER WORKSPACE</span>
    <h1 className="serif">Welcome, {profile.full_name || "there"}</h1>
    <p>Find a certified professional, ask questions, and keep your service bookings together.</p>
    <div className="customer-dashboard-grid">
      <Link className="card" href="/marketplace"><BriefcaseBusiness/><b>Find a professional</b><span>Browse service categories and verified profiles.</span></Link>
      <Link className="card" href="/customer/bookings"><CalendarDays/><b>Your bookings</b><span>{count ?? 0} booking{count === 1 ? "" : "s"} on your account.</span></Link>
      <Link className="card" href="/customer/messages"><MessageSquareText/><b>Messages</b><span>Continue conversations with professionals.</span></Link>
    </div>
  </main></DashboardLayout>;
}
