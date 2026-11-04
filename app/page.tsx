import Link from "next/link";
import { ArrowRight, ArrowUpRight, BookOpen, BriefcaseBusiness, CheckCircle2, Compass, GraduationCap, Scissors, Sparkles } from "lucide-react";
import { createClient } from "@/lib/supabase/server";

type Course = { id: string; title: string; summary: string | null; category: string; level: string };
type Professional = { id: string; display_name: string; headline: string; category: string; location: string | null };
type Category = { category_id: string; slug: string; name: string; description: string; professional_count: number };

export default async function Home() {
  const db = await createClient();
  let courses: Course[] = [];
  let professionals: Professional[] = [];
  let categories: Category[] = [];
  let courseCount: number | null = null;
  if (db) {
    const [courseResult, marketplaceResult, countResult] = await Promise.all([
      db.from("courses").select("id,title,summary,category,level").eq("status", "published").order("created_at", { ascending: false }).limit(3),
      db.functions.invoke("marketplace-public", { body: { operation: "discovery", filters: {} } }),
      db.from("courses").select("id", { count: "exact", head: true }).eq("status", "published"),
    ]);
    courses = (courseResult.data ?? []) as Course[];
    professionals = ((marketplaceResult.data?.professionals ?? []) as Professional[]).slice(0, 3);
    categories = ((marketplaceResult.data?.categories ?? []) as Category[]).filter((category) => category.professional_count > 0).slice(0, 4);
    courseCount = countResult.count;
  }

  return <main className="landing-wrap">
    <a className="skip-link" href="#main-content">Skip to content</a>
    <header className="site-header"><div className="site-header-inner">
      <Link href="/" className="brand" aria-label="GlowBiz home"><span className="brand-mark" aria-hidden="true">gb</span> GlowBiz</Link>
      <nav className="site-nav" aria-label="Main navigation"><Link href="/courses">Learning</Link><Link href="/marketplace">Explore services</Link><Link href="/signup?role=tutor">Teach with us</Link></nav>
      <div className="site-actions"><Link className="btn btn-light" href="/login">Log in</Link><Link className="btn" href="/signup">Get started <ArrowRight size={15}/></Link></div>
    </div></header>

    <section id="main-content" className="landing-container hero-section">
      <div><span className="eyebrow"><Sparkles size={14}/> Skills, confidence and opportunity</span>
        <h1 className="hero-title serif">Learn a skill.<br/>Shape your <em>future.</em></h1>
        <p className="hero-copy">Build practical skills with guided learning, show what you can do, and explore opportunities to turn your talent into work.</p>
        <div className="hero-actions"><Link className="btn" href="/signup?role=student">Start learning <ArrowRight size={16}/></Link><Link className="btn btn-light" href="/marketplace">Find a professional <ArrowUpRight size={15}/></Link></div>
        <div className="hero-note"><span><CheckCircle2 size={15}/> Learn at your pace</span><span><CheckCircle2 size={15}/> Browse services without an account</span></div>
      </div>
      <div className="hero-board" aria-label="A learning journey from first lesson to earning">
        <div className="board-kicker">Your next chapter</div><div className="board-title serif">From first lesson to new opportunity</div>
        <div className="journey-stack">
          {[{icon:BookOpen,n:"01",title:"Learn the foundations",sub:"Short lessons, clear steps"},{icon:Scissors,n:"02",title:"Practise your craft",sub:"Build practical experience"},{icon:GraduationCap,n:"03",title:"Show your skills",sub:"Complete course assessments"}].map(({icon:Icon,n,title,sub})=><div className="journey-card" key={n}><span className="journey-icon"><Icon size={20}/></span><span><b>{title}</b><small>{sub}</small></span><span className="journey-number">{n}</span></div>)}
        </div><div className="board-footer"><span>Keep moving forward</span><small>One step at a time</small></div>
      </div>
    </section>

    {courseCount !== null && <section className="proof-strip" aria-label="GlowBiz catalogue"><div className="landing-container proof-grid"><div className="proof-item"><span className="proof-number">{courseCount}</span><span className="proof-label">published {courseCount === 1 ? "course" : "courses"}<br/>available to explore</span></div><div className="proof-item"><span className="proof-number"><Compass size={24}/></span><span className="proof-label">Browse learning and services<br/>in one place</span></div><div className="proof-item"><span className="proof-number"><BriefcaseBusiness size={23}/></span><span className="proof-label">Build practical skills<br/>for work and enterprise</span></div></div></section>}

    <section className="landing-container section-space"><div className="section-heading"><div><div className="section-overline">Learn a trade</div><h2 className="section-title serif">Start with what interests you.</h2><p className="section-copy">Explore published programmes and courses. You can browse before creating an account.</p></div><Link className="btn btn-light" href="/courses">View all courses <ArrowRight size={14}/></Link></div>
      {courses.length ? <div className="course-grid">{courses.map((course)=><Link href="/courses" className="card course-card" key={course.id}><span className="course-badge"><BookOpen size={20}/></span><h3>{course.title}</h3><p>{course.summary || "Explore this practical course and see what you can learn."}</p><div className="course-meta"><span>{course.category}</span><span>{course.level}</span></div></Link>)}</div> : <div className="card empty-state"><b>Courses are being prepared</b><p>There are no published courses to feature right now. Check back soon or explore the marketplace.</p><Link href="/marketplace" className="btn btn-light">Explore services <ArrowRight size={14}/></Link></div>}
    </section>

    <section className="section-tint"><div className="landing-container section-space"><div className="section-heading"><div><div className="section-overline">How it works</div><h2 className="section-title serif">A path you can take one step at a time.</h2></div></div><ol className="journey-steps">{[{title:"Choose a course",text:"Find a subject that fits your interests and goals."},{title:"Learn and practise",text:"Work through lessons and build skills at your own pace."},{title:"Complete your work",text:"Submit assessments and receive feedback from a tutor."},{title:"Explore what’s next",text:"Use your experience to pursue certification and work opportunities."}].map((step,i)=><li className="journey-step" key={step.title}><span className="journey-step-number">{i+1}</span><b>{step.title}</b><p>{step.text}</p></li>)}</ol></div></section>

    <section className="landing-container section-space"><div className="section-heading"><div><div className="section-overline">Marketplace</div><h2 className="section-title serif">Find skilled professionals nearby.</h2><p className="section-copy">Browse currently published profiles and service categories. Availability and services may vary by professional.</p></div><Link className="btn btn-light" href="/marketplace">Explore marketplace <ArrowRight size={14}/></Link></div>
      {categories.length > 0 && <div className="category-grid">{categories.map((category)=><Link className="category-card" href={`/marketplace?category=${category.slug}`} key={category.category_id}><b>{category.name}</b><small>{category.description || `${category.professional_count} published ${category.professional_count === 1 ? "professional" : "professionals"}`}</small></Link>)}</div>}
      <h3 className="subsection-title">Featured professionals</h3>
      {professionals.length ? <div className="professional-grid">{professionals.map((person)=><Link className="card professional-card" href={`/professionals/${person.id}`} key={person.id}><div className="professional-avatar" aria-hidden="true">{person.display_name.trim().charAt(0).toUpperCase()}</div><h3>{person.display_name}</h3><p>{person.headline} · {person.category}{person.location ? ` · ${person.location}` : ""}</p><span className="text-link">View profile <ArrowRight size={13}/></span></Link>)}</div> : <div className="card empty-state"><b>No professional profiles to feature yet</b><p>Published profiles will appear here when professionals are ready to be discovered.</p><Link href="/marketplace" className="text-link">Browse the marketplace <ArrowRight size={13}/></Link></div>}
    </section>

    <section className="section-tint"><div className="landing-container section-space"><div className="section-heading"><div><div className="section-overline">Made for learning and work</div><h2 className="section-title serif">Tools for every part of the journey.</h2></div></div><div className="benefit-grid">{[{icon:GraduationCap,title:"For learners",text:"Follow structured lessons, track your progress, submit assessments and get tutor feedback.",href:"/signup?role=student",cta:"Start learning"},{icon:BookOpen,title:"For tutors and training partners",text:"Share your expertise, support learners and contribute to practical vocational education.",href:"/signup?role=tutor",cta:"Become a tutor"},{icon:BriefcaseBusiness,title:"For professionals and customers",text:"Customers can explore public services. Eligible graduates can apply to publish a professional profile.",href:"/marketplace",cta:"Find a professional"}].map(({icon:Icon,title,text,href,cta})=><article className="card benefit-card" key={title}><span className="course-badge"><Icon size={20}/></span><h3>{title}</h3><p>{text}</p><Link className="text-link" href={href}>{cta} <ArrowRight size={13}/></Link></article>)}</div><p className="certified-cta">Already earned a GlowBiz certificate? <Link href="/professional/profile">Apply to become a certified professional <ArrowRight size={13}/></Link></p></div></section>

    <section id="faq" className="landing-container section-space"><div className="section-heading"><div><div className="section-overline">Frequently asked questions</div><h2 className="section-title serif">A few useful things to know.</h2></div></div><div className="faq-grid">{[{q:"Can I browse before I register?",a:"Yes. Published courses, professional profiles and services can be browsed publicly. An account is needed for enrolment, booking and other protected actions."},{q:"How do certificates work?",a:"Certificates depend on the configured course requirements and approval workflow. Completing a course does not by itself guarantee that a certificate will be issued."},{q:"How do I become a tutor?",a:"Create an account as a tutor and submit your details. Tutor access and course publication are subject to platform review."},{q:"Where can I get help?",a:"Learners can contact tutors through consultations in their learning account. Customers can use the booking conversation to discuss an appointment."}].map((item)=><details className="card faq-item" key={item.q}><summary>{item.q}</summary><p>{item.a}</p></details>)}</div></section>

    <footer className="site-footer"><div className="landing-container"><div className="footer-grid"><div><Link href="/" className="brand" style={{color:"white"}}><span className="brand-mark" aria-hidden="true">gb</span> GlowBiz</Link><p>Practical learning and new opportunities, built around your next step.</p></div><div><h2 className="footer-heading">Learn</h2><div className="footer-links"><Link href="/courses">Explore courses</Link><Link href="/signup?role=student">Start learning</Link></div></div><div><h2 className="footer-heading">Work with us</h2><div className="footer-links"><Link href="/signup?role=tutor">Become a tutor</Link><Link href="/professional/profile">Certified professional</Link></div></div><div><h2 className="footer-heading">Discover</h2><div className="footer-links"><Link href="/marketplace">Find a professional</Link><Link href="#faq">Help and FAQs</Link></div></div></div><div className="footer-bottom"><span>© {new Date().getFullYear()} GlowBiz</span><span>Learn · Practise · Build opportunity</span></div></div></footer>
  </main>;
}
