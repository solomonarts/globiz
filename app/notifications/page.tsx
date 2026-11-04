import Link from "next/link";
import { redirect } from "next/navigation";
import { Bell, CheckCheck } from "lucide-react";
import { getProfile } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { markAllNotificationsRead, markNotificationRead, saveNotificationPreference } from "@/app/actions";

type Notice = { id: string; notification_type: string; title: string; body: string; entity_type: string | null; entity_id: string | null; read_at: string | null; created_at: string };
type Preference = { notification_type: string; in_app_enabled: boolean; email_enabled: boolean };
const types: [string, string][] = [
  ["enrolment", "Enrolment decisions"], ["account_status", "Account status"], ["tutor_approval", "Tutor approval"],
  ["course_availability", "Course availability"], ["lesson_availability", "New lessons"], ["assessment_result", "Assessment results"],
  ["pending_assignment", "Assessments and assignments"], ["announcement", "Announcements"], ["certification_eligibility", "Certification eligibility"],
  ["certification_recommendation", "Certification recommendations"], ["certification", "Certification decisions"], ["certificate", "Certificates"],
  ["content_decision", "Content review decisions"], ["consultation_message", "Tutor consultation messages"], ["booking", "Bookings"],
  ["customer_message", "Marketplace messages"], ["professional_profile", "Professional profile decisions"],
];
export default async function NotificationsPage({ searchParams }: { searchParams: Promise<{ error?: string; message?: string }> }) {
  const [profile, notice] = await Promise.all([getProfile(), searchParams]);
  if (!profile) redirect("/login");
  if (profile.account_status !== "active") redirect("/account/status");
  const db = await createClient();
  if (!db) return <main style={{ padding: 32 }}>Connect Supabase to manage notifications.</main>;
  const [{ data: rawNotices }, { data: rawPrefs }] = await Promise.all([
    db.from("notifications").select("id,notification_type,title,body,entity_type,entity_id,read_at,created_at").eq("user_id", profile.id).order("created_at", { ascending: false }).limit(100),
    db.from("notification_preferences").select("notification_type,in_app_enabled,email_enabled").eq("user_id", profile.id),
  ]);
  const notices = (rawNotices ?? []) as Notice[];
  const prefs = new Map(((rawPrefs ?? []) as Preference[]).map((x) => [x.notification_type, x]));
  const unread = notices.filter((x) => !x.read_at).length;
  return <main style={{ maxWidth: 920, margin: "auto", padding: "30px 20px 56px" }}>
    <Link href={`/${profile.role}`} style={{ fontSize: 12, color: "#176b4d" }}>← Workspace</Link>
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, marginTop: 16, flexWrap: "wrap" }}>
      <div><span className="pill"><Bell size={13} /> Notifications</span><h1 className="serif" style={{ fontWeight: 500, margin: "10px 0 4px" }}>Your updates</h1><p style={{ color: "#78877e", fontSize: 12, margin: 0 }}>{unread} unread · Latest 100 notifications</p></div>
      {unread > 0 && <form action={markAllNotificationsRead}><button className="btn btn-light"><CheckCheck size={15} /> Mark all read</button></form>}
    </div>
    {notice.error && <p role="alert" style={{ color: "#a44235", fontSize: 12 }}>{notice.error}</p>}{notice.message && <p role="status" style={{ color: "#176b4d", fontSize: 12 }}>{notice.message}</p>}
    <section style={{ display: "grid", gap: 8, marginTop: 18 }} aria-label="Notifications">
      {notices.map((item) => <article className="card" key={item.id} style={{ padding: 15, borderLeft: `3px solid ${item.read_at ? "#e3e9e4" : "#5d9274"}` }}>
        <div style={{ display: "flex", justifyContent: "space-between", gap: 12, alignItems: "start" }}><div><b style={{ fontSize: 13 }}>{item.title}</b><p style={{ margin: "5px 0", color: "#65736b", fontSize: 12, lineHeight: 1.55 }}>{item.body}</p><time style={{ color: "#8a958e", fontSize: 10 }} dateTime={item.created_at}>{new Date(item.created_at).toLocaleString("en-UG")}</time></div>
          {!item.read_at && <form action={markNotificationRead}><input type="hidden" name="notificationId" value={item.id} /><button className="btn btn-light" style={{ padding: "7px 10px", fontSize: 10 }}>Mark read</button></form>}
        </div>
      </article>)}
      {!notices.length && <div className="card" style={{ padding: 30, textAlign: "center", color: "#78877e", fontSize: 13 }}>You are all caught up. New updates will appear here.</div>}
    </section>
    <section className="card" style={{ marginTop: 24, padding: 18 }}><h2 style={{ fontSize: 16, margin: "0 0 5px" }}>Notification preferences</h2><p style={{ color: "#78877e", fontSize: 11, margin: "0 0 12px" }}>Choose which in-app updates you want. Email notifications are not enabled yet.</p>
      <div style={{ display: "grid", gap: 4 }}>{types.map(([type, label]) => { const enabled = prefs.get(type)?.in_app_enabled ?? true; return <form key={type} action={saveNotificationPreference} style={{ display: "grid", gridTemplateColumns: "1fr 145px auto", gap: 8, alignItems: "center", borderTop: "1px solid #edf0ed", padding: "8px 0" }}>
        <input type="hidden" name="notificationType" value={type} /><label htmlFor={`pref-${type}`} style={{ fontSize: 12, color: "#46584e" }}>{label}</label><select id={`pref-${type}`} name="enabled" className="input" defaultValue={enabled ? "on" : "off"}><option value="on">In app on</option><option value="off">In app off</option></select><button className="btn btn-light" style={{ padding: "7px 10px", fontSize: 10 }}>Save</button>
      </form>; })}</div>
    </section>
    <style>{"@media(max-width:580px){form[style*=grid-template-columns]{grid-template-columns:1fr 120px!important}form[style*=grid-template-columns] button{grid-column:1/-1;justify-self:start}}"}</style>
  </main>;
}
