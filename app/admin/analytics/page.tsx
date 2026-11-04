import Link from "next/link";
import { redirect } from "next/navigation";
import { getProfile } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

type Row = Record<string, string | number | null | boolean>;
const value = (x: unknown, digits = 1) => typeof x === "number" ? x.toLocaleString("en-UG", { maximumFractionDigits: digits }) : x == null ? "—" : String(x);
function Table({ title, rows, columns }: { title: string; rows: Row[]; columns: [string, string][] }) { return <section className="card" style={{ padding: 17, overflowX: "auto" }}><h2 style={{ fontSize: 15, margin: "0 0 10px" }}>{title}</h2>{rows.length ? <table style={{ borderCollapse: "collapse", width: "100%", fontSize: 11 }}><thead><tr>{columns.map(([key, label]) => <th key={key} style={{ textAlign: "left", padding: 8, color: "#78877e", borderBottom: "1px solid #e8ece8" }}>{label}</th>)}</tr></thead><tbody>{rows.map((row, i) => <tr key={String(row.course_id ?? row.programme_id ?? row.month ?? row.day ?? row.tutor_id ?? row.cohort_id ?? i)}>{columns.map(([key]) => <td key={key} style={{ padding: 8, borderBottom: "1px solid #edf0ed" }}>{value(row[key])}</td>)}</tr>)}</tbody></table> : <p style={{ fontSize: 12, color: "#87928a" }}>No records for this period.</p>}</section> }
export default async function Analytics({ searchParams }: { searchParams: Promise<{ start?: string; end?: string; grain?: string }> }) {
  const [profile, filters] = await Promise.all([getProfile(), searchParams]);
  if (!profile) redirect("/login");
  if (profile.role !== "admin" || profile.account_status !== "active") redirect(`/${profile.role}`);
  const db = await createClient();
  if (!db) return <main style={{ padding: 32 }}>Connect Supabase to view performance analytics.</main>;
  const start = /^\d{4}-\d{2}-\d{2}$/.test(filters.start ?? "") ? filters.start! : "";
  const end = /^\d{4}-\d{2}-\d{2}$/.test(filters.end ?? "") ? filters.end! : "";
  if (start && end && end < start) redirect("/admin/analytics?error=End+date+must+follow+start+date");
  const grain = ["day", "week", "month"].includes(filters.grain ?? "") ? filters.grain! : "day";
  const {data:analytics,error:analyticsError}=await db.functions.invoke("admin-reporting",{body:{operation:"analytics",start_date:start||undefined,end_date:end||undefined}});
  if(analyticsError)return <main style={{padding:32}}>Unable to load administrator analytics. Deploy the admin-reporting Edge Function.</main>;
  const {courses,programmes,modules,assessments,tutors:tutorRows,certificates,feedback,cohorts,marketplace,activity}=analytics as Record<string,unknown[]>;
  const bins = new Map<string, number>();
  for (const row of (activity ?? []) as Row[]) {
    const date = new Date(String(row.day));
    if (Number.isNaN(date.getTime())) continue;
    let key = String(row.day);
    if (grain === "month") key = `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
    if (grain === "week") { const d = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate())); d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7)); key = d.toISOString().slice(0, 10); }
    const bin = JSON.stringify([key, String(row.course_title ?? "Unassigned"), String(row.metric)]); bins.set(bin, (bins.get(bin) ?? 0) + Number(row.event_count ?? 0));
  }
  const activityRows = [...bins].map(([key, count]) => { const [period, course, metric] = JSON.parse(key) as string[]; return { period, course, metric, count }; }).sort((a, b) => b.period.localeCompare(a.period) || a.metric.localeCompare(b.metric)) as Row[];
  const row = (data: unknown) => (data ?? []) as Row[];
  return <main style={{ maxWidth: 1180, margin: "auto", padding: "30px 20px 56px" }}><Link href="/admin">← Administration</Link><h1 className="serif" style={{ fontWeight: 500 }}>Performance analytics</h1><p style={{ fontSize: 12, color: "#78877e", lineHeight: 1.6 }}>Counts are records; percentages use their stated denominators; averages exclude missing scores and ratings. Learning event totals are activity counts, not unique learners.</p>
    <form method="get" action="/admin/analytics" className="card" style={{ padding: 13, display: "flex", gap: 10, flexWrap: "wrap", alignItems: "end", marginBottom: 18 }}><label style={label}>From<input className="input" type="date" name="start" defaultValue={start} /></label><label style={label}>To<input className="input" type="date" name="end" defaultValue={end} /></label><label style={label}>Activity grouping<select name="grain" className="input" defaultValue={grain}><option value="day">Daily</option><option value="week">Weekly</option><option value="month">Monthly</option></select></label><button className="btn">Apply period</button><span style={{ fontSize: 10, color: "#87928a" }}>Activity uses this period and shows up to 2,000 daily course/event groups. Comparisons and monthly feedback/marketplace trends are all-time.</span></form>
    <div style={{ display: "grid", gap: 14 }}>
      <Table title="Daily, weekly or monthly learning activity" rows={activityRows} columns={[["period", "Period start"], ["course", "Course"], ["metric", "Event type"], ["count", "Event count"]]} />
      <Table title="Course performance" rows={row(courses)} columns={[["course_title", "Course"], ["status", "Status"], ["enrolments", "Enrolments"], ["active", "Active"], ["completed", "Completed"], ["pending", "Pending"], ["average_progress", "Average progress %"], ["feedback_count", "Ratings"], ["average_rating", "Average rating / 5"]]} />
      <Table title="Programme comparisons" rows={row(programmes)} columns={[["programme_title", "Programme"], ["course_count", "Courses"], ["enrolments", "Enrolments"], ["completed_enrolments", "Completed"], ["average_progress", "Average progress %"]]} />
      <Table title="Module progression" rows={row(modules)} columns={[["course_title", "Course"], ["module_title", "Module"], ["lesson_count", "Lessons"], ["lesson_completions", "Completed lesson records"], ["completion_records_percent", "Completion records %"]]} />
      <Table title="Assessment outcomes" rows={row(assessments)} columns={[["course_title", "Course"], ["assessment_title", "Assessment"], ["attempts", "Attempts"], ["reviewed", "Reviewed"], ["passed", "Passed"], ["below_pass", "Below pass"], ["pass_rate_percent", "Pass rate %"], ["average_reviewed_score", "Average score %"]]} />
      <Table title="Tutor engagement" rows={row(tutorRows)} columns={[["tutor_name", "Tutor"], ["assigned_courses", "Assigned courses"], ["published_courses", "Published"], ["graded_submissions", "Graded submissions"], ["content_submissions", "Content submissions"], ["consultations", "Consultations"]]} />
      <Table title="Certification outcomes" rows={row(certificates)} columns={[["course_title", "Course"], ["certification_title", "Certification"], ["applications", "Applications"], ["approved_count", "Approved"], ["rejected_count", "Rejected"], ["pending_count", "Pending"], ["changes_requested_count", "Changes requested"]]} />
      <Table title="Feedback trends (approved feedback only)" rows={row(feedback)} columns={[["month", "Month"], ["course_title", "Course"], ["module_title", "Module"], ["rating_count", "Ratings"], ["average_rating", "Average rating / 5"]]} />
      <Table title="Cohort performance" rows={row(cohorts)} columns={[["cohort_name", "Cohort"], ["students", "Students"], ["completed_students", "Completed"], ["average_progress", "Average progress %"]]} />
      <Table title="Marketplace activity" rows={row(marketplace)} columns={[["month", "Month"], ["professional_name", "Professional"], ["booking_requests", "Requests"], ["confirmed_or_completed", "Confirmed or completed"], ["completed", "Completed"], ["cancelled", "Cancelled"], ["booking_conversion_percent", "Conversion %"], ["average_agreed_price", "Average agreed price"]]} />
    </div></main>;
}
const label = { display: "grid", gap: 5, fontSize: 10, color: "#718078" } as const;
