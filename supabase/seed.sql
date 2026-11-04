-- Run after creating and approving a tutor in Supabase Auth.
insert into public.programmes(title,slug,summary,category,status) values
 ('Beauty & Personal Care','beauty-personal-care','Practical beauty skills and salon readiness.','Beauty','published'),
 ('Fashion & Tailoring','fashion-tailoring','Build practical garment construction skills.','Fashion','published'),
 ('Food & Catering','food-catering','Learn food preparation, safety, and small catering operations.','Catering','published'),
 ('Creative Services','creative-services','Turn creative talent into a sustainable service business.','Creative','published')
on conflict(slug) do nothing;

with tutor as (select id from public.profiles where role='tutor' and tutor_approved order by created_at limit 1), programme as (select id from public.programmes where slug='beauty-personal-care')
insert into public.courses(programme_id,owner_id,title,slug,summary,category,level,status)
select programme.id,tutor.id,'Salon Foundations','salon-foundations','Client care, hygiene, tools, and essential salon practice.','Hair & Beauty','beginner','published' from tutor,programme
on conflict(slug) do nothing;

with course as (select id from public.courses where slug='salon-foundations')
insert into public.modules(course_id,title,description,position)
select course.id, seed.title, seed.description, seed.position from course cross join (values
 ('A safe and welcoming salon','Set up a clean, accessible workstation and understand professional hygiene.',1),
 ('Consultation and client care','Practice clear consultations, consent, service expectations, and aftercare.',2),
 ('Tools and practical technique','Identify essential tools and apply foundational salon techniques.',3)
) as seed(title,description,position)
where not exists(select 1 from public.modules existing where existing.course_id=course.id and existing.title=seed.title);

with modules as (select id,title from public.modules where title in ('A safe and welcoming salon','Consultation and client care','Tools and practical technique'))
insert into public.lessons(module_id,title,theory,duration_minutes,position,status)
select modules.id, seed.title, seed.theory, seed.duration_minutes, seed.position, 'published' from modules join (values
 ('A safe and welcoming salon','The workstation checklist','Clean and sanitize tools between clients. Keep clean and used materials separate, check product labels, and make sure the client can move safely around the service area.',12,1),
 ('Consultation and client care','A thoughtful client consultation','Ask about goals, sensitivities, previous treatments, and preferred outcomes. Explain the process and confirm consent before starting.',15,1),
 ('Tools and practical technique','Tools are part of the craft','Choose tools suited to the service, inspect them before use, and clean and store them according to the maker guidance.',14,1)
) as seed(module_title,title,theory,duration_minutes,position) on modules.title=seed.module_title
where not exists(select 1 from public.lessons existing where existing.module_id=modules.id and existing.title=seed.title);
