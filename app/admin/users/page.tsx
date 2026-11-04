import Link from "next/link";
import { redirect } from "next/navigation";
import { Activity, Search, ShieldCheck, UserCheck, Users } from "lucide-react";
import { getProfile } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { adminDeleteUser, adminResetProfile, adminSetUserStatus, approveManagedUser } from "@/app/actions";

type Person = { id: string; full_name: string; email: string | null; role: string; account_status: string; tutor_approved: boolean; tutor_application_status: string; created_at: string };
type Filters = { error?: string; message?: string; q?: string; role?: string; status?: string };

export default async function AdminUsers({ searchParams }: { searchParams: Promise<Filters> }) {
  const [profile, filters] = await Promise.all([getProfile(), searchParams]);
  if (!profile) redirect("/login");
  if (profile.role !== "admin" || profile.account_status !== "active") redirect(`/${profile.role}`);
  const db = await createClient();
  if (!db) return <main style={{ padding: 28 }}>Supabase unavailable.</main>;

  const role = ["student", "tutor", "customer"].includes(filters.role ?? "") ? filters.role! : "all";
  const status = ["approval", "pending", "active", "suspended", "deactivated"].includes(filters.status ?? "") ? filters.status! : "all";
  const search = (filters.q ?? "").trim().replace(/[%,_()]/g, "").slice(0, 80);
  let query = db.from("profiles").select("id,full_name,email,role,account_status,tutor_approved,tutor_application_status,created_at", { count: "exact" }).neq("role", "admin").order("created_at", { ascending: false }).limit(500);
  if (role !== "all") query = query.eq("role", role);
  if (status === "approval") {
    if (role === "tutor") query = query.eq("tutor_approved", false);
    else if (role === "student" || role === "customer") query = query.eq("account_status", "pending");
    else query = query.or("and(role.eq.student,account_status.eq.pending),and(role.eq.customer,account_status.eq.pending),and(role.eq.tutor,tutor_approved.eq.false)");
  } else if (status !== "all") query = query.eq("account_status", status);
  if (search) query = status === "approval" ? query.ilike("full_name", `%${search}%`) : query.or(`full_name.ilike.%${search}%,email.ilike.%${search}%`);

  const [accountResult, totalUsers, activeUsers, pendingStudents, pendingTutors, pendingCustomers, suspendedUsers] = await Promise.all([
    query,
    db.from("profiles").select("id", { count: "exact", head: true }).neq("role", "admin"),
    db.from("profiles").select("id", { count: "exact", head: true }).neq("role", "admin").eq("account_status", "active"),
    db.from("profiles").select("id", { count: "exact", head: true }).eq("role", "student").eq("account_status", "pending"),
    db.from("profiles").select("id", { count: "exact", head: true }).eq("role", "tutor").eq("tutor_approved", false),
    db.from("profiles").select("id", { count: "exact", head: true }).eq("role", "customer").eq("account_status", "pending"),
    db.from("profiles").select("id", { count: "exact", head: true }).neq("role", "admin").eq("account_status", "suspended"),
  ]);
  const rows = (accountResult.data ?? []) as Person[];
  const awaitingApproval = (pendingStudents.count ?? 0) + (pendingTutors.count ?? 0) + (pendingCustomers.count ?? 0);
  const badge = (user: Person) => user.role === "tutor" ? user.tutor_approved ? "Approved tutor" : "Awaiting approval" : user.account_status === "pending" ? "Awaiting approval" : user.account_status;
  const needsApproval = (user: Person) => user.role === "tutor" ? !user.tutor_approved : user.account_status === "pending";

  return <main style={{ minHeight: "100vh", background: "#f7f8fc" }}>
    <section style={{ maxWidth: 1240, margin: "auto", padding: "30px 24px 56px" }}>
      <Link href="/admin" style={{ fontSize: 12, color: "#176b4d" }}>← Administration</Link>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "end", gap: 16, flexWrap: "wrap", marginTop: 18 }}>
        <div><div className="pill"><Users size={13} /> USER ADMINISTRATION</div><h1 className="serif" style={{ fontSize: 36, fontWeight: 500, margin: "10px 0 5px" }}>Users &amp; accounts</h1><p style={{ margin: 0, fontSize: 13, color: "#78877e" }}>Review approvals, manage access and maintain account records.</p></div>
        <Link className="btn btn-light" href="/admin/people">Open people &amp; enrolments</Link>
      </div>
      {filters.error && <p role="alert" style={{ color: "#a44235", fontSize: 13 }}>{filters.error}</p>}{filters.message && <p role="status" style={{ color: "#176b4d", fontSize: 13 }}>{filters.message}</p>}

      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(190px,1fr))", gap: 12, margin: "22px 0" }}>
        {[
          { label: "Total user accounts", value: totalUsers.count ?? 0, icon: Users },
          { label: "Awaiting approval", value: awaitingApproval, icon: UserCheck },
          { label: "Active accounts", value: activeUsers.count ?? 0, icon: Activity },
          { label: "Suspended accounts", value: suspendedUsers.count ?? 0, icon: ShieldCheck },
        ].map(card => <article className="card" key={card.label} style={{ padding: 17 }}><div style={{ display: "flex", justifyContent: "space-between", color: "#78877e", fontSize: 12 }}>{card.label}<card.icon size={16} /></div><b style={{ display: "block", marginTop: 8, fontSize: 26 }}>{card.value}</b></article>)}
      </div>

      <section className="card" style={{ overflow: "hidden" }}>
        <form method="get" style={{ padding: 16, display: "flex", gap: 9, alignItems: "center", flexWrap: "wrap", borderBottom: "1px solid #e8ece8" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, flex: "1 1 230px" }}><Search size={16} color="#849188" /><input className="input" name="q" defaultValue={search} placeholder={status === "approval" ? "Search by name" : "Search name or email"} aria-label="Search users" /></div>
          <select className="input" name="role" defaultValue={role} aria-label="Filter by role"><option value="all">All roles</option><option value="student">Students</option><option value="tutor">Tutors</option><option value="customer">Customers</option></select>
          <select className="input" name="status" defaultValue={status} aria-label="Filter by account status"><option value="all">All account states</option><option value="approval">Needs approval</option><option value="pending">Pending account status</option><option value="active">Active</option><option value="suspended">Suspended</option><option value="deactivated">Deactivated</option></select>
          <button className="btn">Apply filters</button><Link href="/admin/users" style={{ fontSize: 12, color: "#176b4d" }}>Clear</Link>
        </form>
        <div style={{ overflowX: "auto" }}><table className="table" style={{ width: "100%", minWidth: 900, borderCollapse: "collapse" }}>
          <thead><tr><th>USER</th><th>ROLE</th><th>APPROVAL / ACCESS</th><th>JOINED</th><th>ACCOUNT ACTIONS</th></tr></thead>
          <tbody>{rows.map(user => <tr key={user.id}>
            <td><b>{user.full_name || "Name not set"}</b><small style={{ display: "block", color: "#849188", marginTop: 4 }}>{user.email ?? "No email on profile"}</small></td>
            <td style={{ textTransform: "capitalize" }}>{user.role}</td>
            <td><span className="pill" style={{ background: needsApproval(user) ? "#fff4df" : "#eff7f1", color: needsApproval(user) ? "#87602a" : "#326749" }}>{badge(user)}</span><small style={{ display: "block", color: "#849188", marginTop: 5 }}>{user.role === "tutor" ? `Account ${user.account_status} · ${user.tutor_application_status.replaceAll("_", " ")}` : `Account ${user.account_status}`}</small></td>
            <td>{new Date(user.created_at).toLocaleDateString("en-UG")}</td>
            <td><div style={{ display: "grid", gap: 7, minWidth: 260 }}>
              {needsApproval(user) ? user.role === "tutor" ? <form action={approveManagedUser}><input type="hidden" name="userId" value={user.id} /><button className="btn" style={{ padding: "7px 10px", fontSize: 11 }}>Approve tutor</button></form> : user.role === "student" ? <form action={approveManagedUser}><input type="hidden" name="userId" value={user.id} /><button className="btn" style={{ padding: "7px 10px", fontSize: 11 }}>Approve student</button></form> : <form action={approveManagedUser}><input type="hidden" name="userId" value={user.id} /><button className="btn" style={{ padding: "7px 10px", fontSize: 11 }}>Approve customer</button></form> : <form action={adminSetUserStatus} style={{ display: "flex", gap: 6 }}><input type="hidden" name="userId" value={user.id} /><select className="input" name="status" defaultValue={user.account_status}><option value="active">Active</option><option value="suspended">Suspended</option><option value="deactivated">Deactivated</option></select><button className="btn btn-light" style={{ padding: "7px 9px", fontSize: 11 }}>Save access</button></form>}
              <div style={{ display: "flex", gap: 7, flexWrap: "wrap" }}><form action={adminResetProfile}><input type="hidden" name="userId" value={user.id} /><input type="hidden" name="returnTo" value="/admin/users" /><button className="btn btn-light" style={{ padding: "6px 8px", fontSize: 10 }}>Reset profile</button></form><details><summary style={{ cursor: "pointer", fontSize: 11, color: "#9f3f36", padding: 7 }}>Delete account</summary><form action={adminDeleteUser} style={{ display: "flex", gap: 5, marginTop: 5 }}><input type="hidden" name="userId" value={user.id} /><input type="hidden" name="returnTo" value="/admin/users" /><input className="input" name="confirmEmail" type="email" required placeholder="Confirm email" /><button className="btn" style={{ background: "#9f3f36", padding: "7px 9px" }}>Delete</button></form></details></div>
            </div></td>
          </tr>)}</tbody>
        </table></div>
        {!accountResult.error && !rows.length && <p style={{ padding: 32, textAlign: "center", color: "#849188" }}>No accounts match these filters.</p>}{accountResult.error && <p role="alert" style={{ padding: 24 }}>Unable to load user accounts.</p>}
        <div style={{ padding: "12px 16px", borderTop: "1px solid #edf0ed", color: "#849188", fontSize: 11 }}>Showing {rows.length} of {accountResult.count ?? 0} matching accounts · Administrator accounts are protected.</div>
      </section>
    </section>
  </main>;
}
