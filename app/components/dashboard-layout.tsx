"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState, type ReactNode } from "react";
import {
  Award, Bell, BookOpen, BriefcaseBusiness, CalendarDays,
  ChartNoAxesCombined, ClipboardCheck, FileBarChart,
  LayoutDashboard, LifeBuoy, Megaphone, MessageSquareText, ShieldCheck,
  Users, UserRound,
  type LucideIcon,
} from "lucide-react";

type DashboardRole = "admin" | "student" | "tutor" | "customer" | "professional";
type NavItem = { label: string; href: string; icon: LucideIcon };

const dashboardNavigation: Record<DashboardRole, { title: string; groups: { label: string; items: NavItem[] }[] }> = {
  admin: { title: "Administration", groups: [
    { label: "Overview", items: [{ label: "Dashboard", href: "/admin", icon: LayoutDashboard }, { label: "Analytics", href: "/admin/analytics", icon: ChartNoAxesCombined }, { label: "Reports", href: "/admin/reports", icon: FileBarChart }] },
    { label: "Manage platform", items: [{ label: "People & accounts", href: "/admin/people", icon: Users }, { label: "Courses & content", href: "/admin/courses", icon: BookOpen }, { label: "Content review", href: "/admin/content", icon: ClipboardCheck }, { label: "Certifications", href: "/admin/certifications", icon: Award }, { label: "Marketplace", href: "/admin/marketplace", icon: BriefcaseBusiness }, { label: "Bookings", href: "/admin/bookings", icon: CalendarDays }, { label: "Feedback", href: "/admin/feedback", icon: MessageSquareText }] },
    { label: "Communication", items: [{ label: "Consultations", href: "/admin/consultations", icon: MessageSquareText }, { label: "Support", href: "/admin/support", icon: LifeBuoy }, { label: "Announcements", href: "/admin/announcements", icon: Megaphone }, { label: "Account requests", href: "/admin/account-requests", icon: UserRound }, { label: "Reported chats", href: "/admin/marketplace-reports", icon: ShieldCheck }, { label: "Notifications", href: "/notifications", icon: Bell }] },
  ] },
  student: { title: "Learning space", groups: [
    { label: "My learning", items: [{ label: "Overview", href: "/student", icon: LayoutDashboard }, { label: "My courses", href: "/student/courses", icon: BookOpen }, { label: "Browse courses", href: "/courses", icon: BookOpen }, { label: "Assessments", href: "/student/assessments", icon: ClipboardCheck }, { label: "Certificates", href: "/student/certificates", icon: Award }, { label: "Consultations", href: "/student/consultations", icon: MessageSquareText }, { label: "Reports", href: "/student/reports", icon: FileBarChart }] },
    { label: "Stay connected", items: [{ label: "Notifications", href: "/notifications", icon: Bell }, { label: "Support", href: "/support", icon: LifeBuoy }, { label: "Marketplace", href: "/marketplace", icon: BriefcaseBusiness }] },
  ] },
  tutor: { title: "Teaching studio", groups: [
    { label: "Teach & support", items: [{ label: "Overview", href: "/tutor", icon: LayoutDashboard }, { label: "My courses", href: "/tutor/courses", icon: BookOpen }, { label: "Assessments", href: "/tutor/assessments", icon: ClipboardCheck }, { label: "Learner outcomes", href: "/tutor/learners", icon: Users }, { label: "Certifications", href: "/tutor/certifications", icon: Award }, { label: "Consultations", href: "/tutor/consultations", icon: MessageSquareText }] },
    { label: "Stay connected", items: [{ label: "Notifications", href: "/notifications", icon: Bell }, { label: "Support", href: "/support", icon: LifeBuoy }] },
  ] },
  customer: { title: "Customer space", groups: [
    { label: "Find & manage services", items: [{ label: "Discover professionals", href: "/marketplace", icon: BriefcaseBusiness }, { label: "My bookings", href: "/customer/bookings", icon: CalendarDays }, { label: "Messages", href: "/customer/messages", icon: MessageSquareText }] },
    { label: "Your account", items: [{ label: "Notifications", href: "/notifications", icon: Bell }, { label: "Support", href: "/support", icon: LifeBuoy }] },
  ] },
  professional: { title: "Professional space", groups: [
    { label: "Manage your services", items: [{ label: "Profile & services", href: "/professional/profile", icon: UserRound }, { label: "Booking requests", href: "/professional/bookings", icon: CalendarDays }, { label: "Marketplace", href: "/marketplace", icon: BriefcaseBusiness }] },
    { label: "Your account", items: [{ label: "Notifications", href: "/notifications", icon: Bell }, { label: "Support", href: "/support", icon: LifeBuoy }] },
  ] },
};

export function DashboardLayout({ role, children }: { role: DashboardRole; children: ReactNode }) {
  const pathname = usePathname();
  const [menuOpen, setMenuOpen] = useState(false);
  const config = dashboardNavigation[role];
  const homeHref = role === "professional" ? "/professional/profile" : `/${role}`;
  const isActive = (href: string) => pathname === href || (href !== `/${role}` && pathname.startsWith(`${href}/`));

  return <div className="dashboard-layout">
    <button className="dashboard-mobile-toggle" type="button" aria-expanded={menuOpen} aria-controls="dashboard-sidebar" onClick={() => setMenuOpen((open) => !open)}>
      <span aria-hidden="true">☰</span> Menu
    </button>
    {menuOpen && <button className="dashboard-backdrop" type="button" aria-label="Close navigation menu" onClick={() => setMenuOpen(false)} />}
    <aside id="dashboard-sidebar" className={`dashboard-sidebar${menuOpen ? " is-open" : ""}`} aria-label={`${config.title} navigation`}>
      <Link href={homeHref} className="dashboard-brand" onClick={() => setMenuOpen(false)}><span className="dashboard-brand-mark">gb</span><span><b>GlowBiz</b><small>{config.title}</small></span></Link>
      <nav className="dashboard-nav">
        {config.groups.map((group) => <section className="dashboard-nav-group" key={group.label}>
          <h2>{group.label}</h2>
          {group.items.map(({ label, href, icon: Icon }) => <Link key={`${label}-${href}`} href={href} className={`dashboard-nav-link${isActive(href) ? " active" : ""}`} aria-current={isActive(href) ? "page" : undefined} onClick={() => setMenuOpen(false)}><Icon size={17} aria-hidden="true"/><span>{label}</span></Link>)}
        </section>)}
      </nav>
      <div className="dashboard-sidebar-footer"><Link href="/" className="dashboard-home-link">View public site</Link><form action="/auth/signout" method="post"><button type="submit">Sign out</button></form></div>
    </aside>
    <div className="dashboard-page-content">{children}</div>
  </div>;
}
