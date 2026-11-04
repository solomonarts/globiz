import Link from "next/link";
import { redirect } from "next/navigation";
import { Activity, BookOpen, CalendarCheck, ChartNoAxesCombined, ClipboardCheck, FileBarChart, LifeBuoy, MessageSquareText, ShieldCheck, Users, UserCheck, UserRound } from "lucide-react";
import { getProfile } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

const managementLinks = [
  ["Users & accounts", "/admin/users", "Approve users, review access and manage account records."],
  ["People & enrolments", "/admin/people", "Review student progress, tutor applications and course enrolments."],
  ["Courses & assignments", "/admin/courses", "Manage course ownership, programmes and publication."],
  ["Content approvals", "/admin/content", "Review submitted lessons and assessments."],
  ["Performance analytics", "/admin/analytics", "Explore learning, assessment and marketplace trends."],
  ["Reports & exports", "/admin/reports", "Create filtered reports for authorized admin use."],
  ["Marketplace bookings", "/admin/bookings", "Review booking requests and service activity."],
  ["User support inbox", "/admin/support", "Respond to questions and account requests."],
  ["Feedback & reviews", "/admin/feedback", "Moderate feedback, reviews and ratings."],
  ["Account action requests", "/admin/account-requests", "Review profile reset and deletion requests."],
  ["Consultations", "/admin/consultations", "Review learner and tutor consultations."],
  ["Marketplace profiles", "/admin/marketplace", "Review professional listings and services."],
] as const;

export default async function AdminHome() {
  const profile = await getProfile();
  if (!profile) redirect("/login");
  if (profile.role !== "admin" || profile.account_status !== "active") redirect(`/${profile.role}`);
  const db = await createClient();
  if (!db) return <main style={{ padding: 32 }}>Connect Supabase to open the admin dashboard.</main>;

  const [users, activeUsers, pendingStudents, pendingTutors, pendingCustomers, pendingEnrolments, publishedCourses, openSupport, pendingContent] = await Promise.all([
    db.from("profiles").select("id", { count: "exact", head: true }).neq("role", "admin"),
    db.from("profiles").select("id", { count: "exact", head: true }).neq("role", "admin").eq("account_status", "active"),
    db.from("profiles").select("id", { count: "exact", head: true }).eq("role", "student").eq("account_status", "pending"),
    db.from("profiles").select("id", { count: "exact", head: true }).eq("role", "tutor").eq("tutor_approved", false),
    db.from("profiles").select("id", { count: "exact", head: true }).eq("role", "customer").eq("account_status", "pending"),
    db.from("enrolments").select("id", { count: "exact", head: true }).eq("status", "pending"),
    db.from("courses").select("id", { count: "exact", head: true }).eq("status", "published"),
    db.from("support_conversations").select("id", { count: "exact", head: true }).eq("status", "open"),
    db.from("content_reviews").select("id", { count: "exact", head: true }).in("decision", ["submitted", "under_review"]),
  ]);
  const approvalCount = (pendingStudents.count ?? 0) + (pendingTutors.count ?? 0) + (pendingCustomers.count ?? 0);
  const cards = [
    { label: "User accounts", value: users.count ?? 0, detail: `${activeUsers.count ?? 0} active`, href: "/admin/users", icon: Users },
    { label: "Approvals needed", value: approvalCount, detail: `${pendingTutors.count ?? 0} tutor applications`, href: "/admin/users?status=approval", icon: UserCheck },
    { label: "Enrolments to review", value: pendingEnrolments.count ?? 0, detail: "Pending course requests", href: "/admin/people", icon: CalendarCheck },
    { label: "Published courses", value: publishedCourses.count ?? 0, detail: "Available to learners", href: "/admin/courses", icon: BookOpen },
    { label: "Content reviews", value: pendingContent.count ?? 0, detail: "Submitted for approval", href: "/admin/content", icon: ClipboardCheck },
    { label: "Open support", value: openSupport.count ?? 0, detail: "Conversations awaiting response", href: "/admin/support", icon: LifeBuoy },
  ];

  return <main style={{ minHeight: "100vh", background: "#f7f8fc" }}>
    <section style={{ maxWidth: 1200, margin: "auto", padding: "32px 24px 56px" }}>
      <div className="pill"><ShieldCheck size={13} /> GLOWBIZ ADMINISTRATION</div>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "end", gap: 16, flexWrap: "wrap", marginTop: 10 }}>
        <div><h1 className="serif" style={{ fontSize: 38, fontWeight: 500, margin: "8px 0 5px" }}>Management overview</h1><p style={{ margin: 0, color: "#718078", fontSize: 13 }}>A current snapshot of accounts, learning activity and support work.</p></div>
        <Link href="/admin/analytics" className="btn btn-light"><ChartNoAxesCombined size={15} /> View analytics</Link>
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(175px,1fr))", gap: 12, marginTop: 23 }}>
        {cards.map(card => <Link className="card" href={card.href} key={card.label} style={{ padding: 17, color: "inherit", textDecoration: "none" }}><div style={{ display: "flex", justifyContent: "space-between", color: "#78877e", fontSize: 11 }}>{card.label}<card.icon size={16} /></div><b style={{ display: "block", fontSize: 28, marginTop: 8 }}>{card.value}</b><small style={{ color: "#87928a" }}>{card.detail}</small></Link>)}
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "minmax(0,1.4fr) minmax(250px,.8fr)", gap: 16, alignItems: "start", marginTop: 20 }} className="admin-overview-grid">
        <section className="card" style={{ padding: 20 }}><div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}><div><h2 style={{ fontSize: 16, margin: 0 }}>Management areas</h2><p style={{ color: "#829087", fontSize: 12, margin: "5px 0 0" }}>Open a workspace to review and manage platform activity.</p></div><Activity size={18} color="#56896c" /></div><div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(220px,1fr))", gap: 9 }}>{managementLinks.map(([label, href, description]) => <Link className="card" href={href} key={href} style={{ padding: 14, color: "inherit", textDecoration: "none" }}><b style={{ fontSize: 13 }}>{label}</b><p style={{ fontSize: 11, lineHeight: 1.5, color: "#829087", margin: "6px 0 0" }}>{description}</p></Link>)}</div></section>
        <aside className="card" style={{ padding: 20 }}><h2 style={{ fontSize: 16, margin: "0 0 13px" }}>Needs attention</h2>{[
          ["User approvals", approvalCount, "/admin/users?status=approval", UserRound],
          ["Enrolment requests", pendingEnrolments.count ?? 0, "/admin/people", CalendarCheck],
          ["Content reviews", pendingContent.count ?? 0, "/admin/content", ClipboardCheck],
          ["Support conversations", openSupport.count ?? 0, "/admin/support", MessageSquareText],
        ].map(([label, value, href, Icon]) => { const I = Icon as typeof Users; return <Link key={String(label)} href={String(href)} style={{ display: "flex", alignItems: "center", gap: 9, padding: "11px 0", borderTop: "1px solid #edf0ed", color: "inherit", fontSize: 12 }}><I size={15} color="#56896c" />{String(label)}<b style={{ marginLeft: "auto" }}>{String(value)}</b></Link>; })}</aside>
      </div>
    </section>
    <style>{"@media(max-width:760px){.admin-overview-grid{grid-template-columns:1fr!important}}"}</style>
  </main>;
}
