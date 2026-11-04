-- Additive normalized schema layer. Existing application tables remain the write source during rollout.
create table public.user_roles(
 user_id uuid not null references public.profiles(id) on delete cascade,
 role text not null check(role in ('student','tutor','admin','customer','professional')),
 is_primary boolean not null default false, granted_by uuid references public.profiles(id), granted_at timestamptz not null default now(),
 revoked_at timestamptz, primary key(user_id,role), check(not is_primary or revoked_at is null)
);
create unique index user_roles_one_primary_idx on public.user_roles(user_id) where is_primary and revoked_at is null;
alter table public.user_roles enable row level security;
create policy "Users read own permitted roles" on public.user_roles for select to authenticated using(user_id=auth.uid() or public.is_admin());
-- Role grants and revocations go through admin_grant_user_role, not direct table writes.
insert into public.user_roles(user_id,role,is_primary,granted_by)
select id,role::text,true,null from public.profiles on conflict(user_id,role) do update set is_primary=true,revoked_at=null;
insert into public.user_roles(user_id,role,is_primary)
select distinct p.profile_id,'professional',false from public.professionals p on conflict(user_id,role) do nothing;
create function public.sync_professional_role_assignment() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_op='INSERT' then insert into public.user_roles(user_id,role,is_primary) values(new.profile_id,'professional',false) on conflict(user_id,role) do update set revoked_at=null;
  return new;
 elsif tg_op='DELETE' then update public.user_roles set revoked_at=now() where user_id=old.profile_id and role='professional' and revoked_at is null;return old; end if;
 return null;
end $$;
create trigger sync_professional_role after insert or delete on public.professionals for each row execute function public.sync_professional_role_assignment();

create function public.sync_profile_role_assignment() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.user_roles(user_id,role,is_primary,granted_by) values(new.id,new.role::text,true,null)
 on conflict(user_id,role) do update set is_primary=true,revoked_at=null;
 return new;
end $$;
create trigger sync_new_profile_role after insert on public.profiles for each row execute function public.sync_profile_role_assignment();
create function public.admin_grant_user_role(p_user_id uuid,p_role text,p_primary boolean default false) returns boolean language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 if p_role not in ('student','tutor','admin','customer','professional') or not exists(select 1 from public.profiles where id=p_user_id) then raise exception 'Invalid role assignment'; end if;
 if p_primary then update public.user_roles set is_primary=false where user_id=p_user_id and revoked_at is null; end if;
 insert into public.user_roles(user_id,role,is_primary,granted_by) values(p_user_id,p_role,p_primary,auth.uid()) on conflict(user_id,role) do update set is_primary=excluded.is_primary,granted_by=auth.uid(),granted_at=now(),revoked_at=null;
 if p_primary and p_role in ('student','tutor','admin','customer') then update public.profiles set role=p_role::public.app_role where id=p_user_id; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'GRANT_USER_ROLE','user_roles',p_user_id,jsonb_build_object('role',p_role,'primary',p_primary));return true;
end $$;
revoke all on function public.admin_grant_user_role(uuid,text,boolean) from public,anon;
grant execute on function public.admin_grant_user_role(uuid,text,boolean) to authenticated;

create table public.admin_permissions(
 id uuid primary key default gen_random_uuid(), admin_id uuid not null references public.profiles(id) on delete cascade,
 permission_key text not null, granted_by uuid references public.profiles(id), granted_at timestamptz not null default now(), revoked_at timestamptz,
 unique(admin_id,permission_key)
);
alter table public.admin_permissions enable row level security;
create policy "Administrators inspect assigned permissions" on public.admin_permissions for select to authenticated using(public.is_admin());
create policy "Administrators manage assigned permissions" on public.admin_permissions for all to authenticated using(public.is_admin()) with check(public.is_admin());
create function public.has_admin_permission(p_permission text) returns boolean language sql stable security definer set search_path=public as $$
 select public.is_admin() and exists(select 1 from public.admin_permissions where admin_id=auth.uid() and permission_key=p_permission and revoked_at is null)
$$;
revoke all on function public.has_admin_permission(text) from public,anon;
grant execute on function public.has_admin_permission(text) to authenticated;

create table public.tutor_assignments(
 id uuid primary key default gen_random_uuid(), tutor_id uuid not null references public.profiles(id) on delete cascade,
 course_id uuid not null references public.courses(id) on delete cascade, assigned_by uuid references public.profiles(id),
 assigned_at timestamptz not null default now(), revoked_at timestamptz, unique(tutor_id,course_id)
);
alter table public.tutor_assignments enable row level security;
create policy "Tutors inspect own assignments" on public.tutor_assignments for select to authenticated using(tutor_id=auth.uid() or public.is_admin());
create policy "Administrators manage tutor assignments" on public.tutor_assignments for all to authenticated using(public.is_admin()) with check(public.is_admin());
insert into public.tutor_assignments(tutor_id,course_id)
select owner_id,id from public.courses on conflict(tutor_id,course_id) do nothing;
create function public.sync_course_owner_assignment() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_op='UPDATE' and new.owner_id is distinct from old.owner_id then update public.tutor_assignments set revoked_at=now() where course_id=new.id and tutor_id=old.owner_id and revoked_at is null; end if;
 insert into public.tutor_assignments(tutor_id,course_id) values(new.owner_id,new.id) on conflict(tutor_id,course_id) do update set revoked_at=null;
 return new;
end $$;
create trigger sync_course_owner_assignment after insert or update of owner_id on public.courses for each row execute function public.sync_course_owner_assignment();
create function public.tutor_assigned_to_course(p_course_id uuid) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.tutor_assignments where tutor_id=auth.uid() and course_id=p_course_id and revoked_at is null)
$$;
revoke all on function public.tutor_assigned_to_course(uuid) from public,anon;
grant execute on function public.tutor_assigned_to_course(uuid) to authenticated;

create table public.course_categories(
 id uuid primary key default gen_random_uuid(), parent_id uuid references public.course_categories(id) on delete set null,
 name text not null, slug text not null unique, description text not null default '', active boolean not null default true,
 created_at timestamptz not null default now()
);
alter table public.courses add column if not exists course_category_id uuid references public.course_categories(id) on delete set null;
insert into public.course_categories(name,slug,description)
select distinct category,lower(regexp_replace(category,'[^a-zA-Z0-9]+','-','g')),category from public.courses where nullif(trim(category),'') is not null on conflict(slug) do nothing;
update public.courses c set course_category_id=cc.id from public.course_categories cc where c.course_category_id is null and lower(regexp_replace(c.category,'[^a-zA-Z0-9]+','-','g'))=cc.slug;
alter table public.course_categories enable row level security;
create policy "Active course categories are public" on public.course_categories for select using(active or public.is_admin());
create policy "Administrators manage course categories" on public.course_categories for all to authenticated using(public.is_admin()) with check(public.is_admin());
create index courses_category_id_idx on public.courses(course_category_id);
insert into public.course_versions(course_id,version,snapshot)
select c.id,c.current_version,to_jsonb(c) from public.courses c on conflict(course_id,version) do nothing;
alter table public.enrolments add column if not exists course_version integer not null default 1;
update public.enrolments e set course_version=c.current_version from public.courses c where c.id=e.course_id;
alter table public.enrolments add constraint enrolments_course_version_fk foreign key(course_id,course_version) references public.course_versions(course_id,version) on delete restrict;

create table public.curriculum_prerequisites(
 id uuid primary key default gen_random_uuid(), course_id uuid not null references public.courses(id) on delete cascade,
 prerequisite_course_id uuid references public.courses(id) on delete cascade, prerequisite_module_id uuid references public.modules(id) on delete cascade,
 created_at timestamptz not null default now(), check((prerequisite_course_id is null)<>(prerequisite_module_id is null)),
 check(prerequisite_course_id is null or prerequisite_course_id<>course_id)
);
create unique index curriculum_course_prereq_unique on public.curriculum_prerequisites(course_id,prerequisite_course_id) where prerequisite_course_id is not null;
create unique index curriculum_module_prereq_unique on public.curriculum_prerequisites(course_id,prerequisite_module_id) where prerequisite_module_id is not null;
alter table public.curriculum_prerequisites enable row level security;
create policy "Published course prerequisites are readable" on public.curriculum_prerequisites for select using(public.is_admin() or exists(select 1 from public.courses c where c.id=course_id and (c.owner_id=auth.uid() or c.status='published')));
create policy "Course owners manage prerequisites" on public.curriculum_prerequisites for all to authenticated using(public.is_admin() or exists(select 1 from public.courses c where c.id=course_id and c.owner_id=auth.uid())) with check(public.is_admin() or exists(select 1 from public.courses c where c.id=course_id and c.owner_id=auth.uid()));

create table public.competency_frameworks(
 id uuid primary key default gen_random_uuid(), name text not null unique, version text not null default '1', description text not null default '', active boolean not null default true, created_at timestamptz not null default now()
);
alter table public.competencies add column if not exists framework_id uuid references public.competency_frameworks(id) on delete set null;
create table public.competency_requirements(
 id uuid primary key default gen_random_uuid(), course_id uuid not null references public.courses(id) on delete cascade,
 competency_id uuid not null references public.competencies(id) on delete cascade, required boolean not null default true,
 created_at timestamptz not null default now(), unique(course_id,competency_id)
);
insert into public.competency_requirements(course_id,competency_id)
select c.id,req from public.courses c cross join lateral unnest(c.required_competencies) req on conflict(course_id,competency_id) do nothing;
alter table public.competency_frameworks enable row level security;alter table public.competency_requirements enable row level security;
create policy "Active competency frameworks are public" on public.competency_frameworks for select using(active or public.is_admin());
create policy "Administrators manage competency frameworks" on public.competency_frameworks for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Course owners and administrators manage requirements" on public.competency_requirements for all to authenticated using(public.is_admin() or exists(select 1 from public.courses c where c.id=course_id and c.owner_id=auth.uid())) with check(public.is_admin() or exists(select 1 from public.courses c where c.id=course_id and c.owner_id=auth.uid()));

create table public.assessment_questions(
 id uuid primary key default gen_random_uuid(), assessment_id uuid not null references public.assessments(id) on delete cascade,
 position integer not null default 0, question_type text not null check(question_type in ('single_choice','multiple_choice','true_false','short_answer','essay','practical')),
 prompt text not null, points numeric(7,2) not null default 1 check(points>0), required boolean not null default true,
 created_at timestamptz not null default now(), unique(assessment_id,position)
);
create table public.assessment_options(
 id uuid primary key default gen_random_uuid(), question_id uuid not null references public.assessment_questions(id) on delete cascade,
 position integer not null default 0, option_text text not null, created_at timestamptz not null default now(), unique(question_id,position), unique(id,question_id)
);
create table public.assessment_answer_keys(
 option_id uuid primary key references public.assessment_options(id) on delete cascade,
 is_correct boolean not null default false, explanation text not null default '', updated_at timestamptz not null default now()
);
create table public.assessment_responses(
 id uuid primary key default gen_random_uuid(), submission_id uuid not null references public.assessment_submissions(id) on delete cascade,
 question_id uuid not null references public.assessment_questions(id) on delete cascade, text_response text not null default '', created_at timestamptz not null default now(), unique(submission_id,question_id), unique(id,question_id)
);
create table public.assessment_response_options(
 response_id uuid not null, question_id uuid not null, option_id uuid not null,
 primary key(response_id,option_id), foreign key(response_id,question_id) references public.assessment_responses(id,question_id) on delete cascade,
 foreign key(option_id,question_id) references public.assessment_options(id,question_id) on delete cascade
);
create function public.guard_assessment_response_context() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.assessment_submissions s join public.assessment_questions q on q.assessment_id=s.assessment_id where s.id=new.submission_id and q.id=new.question_id and s.student_id=auth.uid() and public.current_role()='student' and public.is_active_user()) then raise exception 'Assessment response does not match your submission'; end if;
 return new;
end $$;
create trigger assessment_response_context_guard before insert or update on public.assessment_responses for each row execute function public.guard_assessment_response_context();
alter table public.assessment_questions enable row level security;alter table public.assessment_options enable row level security;alter table public.assessment_answer_keys enable row level security;alter table public.assessment_responses enable row level security;alter table public.assessment_response_options enable row level security;
create policy "Questions readable by course participants" on public.assessment_questions for select to authenticated using(public.is_admin() or exists(select 1 from public.assessments a join public.courses c on c.id=a.course_id where a.id=assessment_id and (c.owner_id=auth.uid() or (a.status='published' and exists(select 1 from public.enrolments e where e.course_id=c.id and e.student_id=auth.uid() and e.status in ('active','completed'))))));
create policy "Course owners manage questions" on public.assessment_questions for all to authenticated using(public.is_admin() or exists(select 1 from public.assessments a join public.courses c on c.id=a.course_id where a.id=assessment_id and c.owner_id=auth.uid())) with check(public.is_admin() or exists(select 1 from public.assessments a join public.courses c on c.id=a.course_id where a.id=assessment_id and c.owner_id=auth.uid()));
create policy "Options readable without answer keys" on public.assessment_options for select to authenticated using(exists(select 1 from public.assessment_questions q join public.assessments a on a.id=q.assessment_id join public.courses c on c.id=a.course_id where q.id=question_id and (public.is_admin() or c.owner_id=auth.uid() or (a.status='published' and exists(select 1 from public.enrolments e where e.course_id=c.id and e.student_id=auth.uid() and e.status in ('active','completed'))))));
create policy "Course owners manage options" on public.assessment_options for all to authenticated using(public.is_admin() or exists(select 1 from public.assessment_questions q join public.assessments a on a.id=q.assessment_id join public.courses c on c.id=a.course_id where q.id=question_id and c.owner_id=auth.uid())) with check(public.is_admin() or exists(select 1 from public.assessment_questions q join public.assessments a on a.id=q.assessment_id join public.courses c on c.id=a.course_id where q.id=question_id and c.owner_id=auth.uid()));
create policy "Answer keys tutor or administrator only" on public.assessment_answer_keys for all to authenticated using(public.is_admin() or exists(select 1 from public.assessment_options o join public.assessment_questions q on q.id=o.question_id join public.assessments a on a.id=q.assessment_id join public.courses c on c.id=a.course_id where o.id=option_id and c.owner_id=auth.uid())) with check(public.is_admin() or exists(select 1 from public.assessment_options o join public.assessment_questions q on q.id=o.question_id join public.assessments a on a.id=q.assessment_id join public.courses c on c.id=a.course_id where o.id=option_id and c.owner_id=auth.uid()));
create policy "Students and assigned tutors read assessment responses" on public.assessment_responses for select to authenticated using(public.is_admin() or exists(select 1 from public.assessment_submissions s join public.assessments a on a.id=s.assessment_id join public.courses c on c.id=a.course_id where s.id=submission_id and (s.student_id=auth.uid() or c.owner_id=auth.uid())));
create policy "Students create own assessment responses" on public.assessment_responses for insert to authenticated with check(exists(select 1 from public.assessment_submissions s where s.id=submission_id and s.student_id=auth.uid() and public.current_role()='student' and public.is_active_user()));
create policy "Participants read chosen options" on public.assessment_response_options for select to authenticated using(exists(select 1 from public.assessment_responses r join public.assessment_submissions s on s.id=r.submission_id join public.assessments a on a.id=s.assessment_id join public.courses c on c.id=a.course_id where r.id=response_id and (public.is_admin() or s.student_id=auth.uid() or c.owner_id=auth.uid())));
create policy "Students select options on own responses" on public.assessment_response_options for insert to authenticated with check(exists(select 1 from public.assessment_responses r join public.assessment_submissions s on s.id=r.submission_id where r.id=response_id and s.student_id=auth.uid() and public.current_role()='student' and public.is_active_user()));
revoke all on public.assessment_answer_keys from anon,authenticated;
grant select,insert,update,delete on public.assessment_questions,public.assessment_options,public.assessment_responses,public.assessment_response_options to authenticated;
grant select,insert,update,delete on public.assessment_answer_keys to authenticated;

create table public.lesson_resources(
 id uuid primary key default gen_random_uuid(), lesson_id uuid not null references public.lessons(id) on delete cascade,
 storage_bucket text not null default 'lesson-resources', storage_path text not null, display_name text not null,
 mime_type text not null, byte_size bigint not null check(byte_size between 1 and 52428800), created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now(), deleted_at timestamptz, unique(storage_bucket,storage_path)
);
alter table public.lesson_resources enable row level security;
create policy "Authorized lesson resources are readable" on public.lesson_resources for select to authenticated using(deleted_at is null and (public.is_admin() or created_by=auth.uid() or exists(select 1 from public.lessons l join public.modules m on m.id=l.module_id where l.id=lesson_id and l.status='published' and exists(select 1 from public.enrolments e where e.course_id=m.course_id and e.student_id=auth.uid() and e.status in ('active','completed')))));
create policy "Course owners manage lesson resources" on public.lesson_resources for all to authenticated using(public.is_admin() or created_by=auth.uid() or exists(select 1 from public.lessons l join public.modules m on m.id=l.module_id join public.courses c on c.id=m.course_id where l.id=lesson_id and c.owner_id=auth.uid())) with check(public.is_admin() or created_by=auth.uid() or exists(select 1 from public.lessons l join public.modules m on m.id=l.module_id join public.courses c on c.id=m.course_id where l.id=lesson_id and c.owner_id=auth.uid()));
create index lesson_resources_lesson_idx on public.lesson_resources(lesson_id) where deleted_at is null;

create table public.payments(
 id uuid primary key default gen_random_uuid(), booking_id uuid not null references public.bookings(id) on delete restrict,
 amount numeric(12,2) not null check(amount>=0), currency text not null default 'UGX', status text not null default 'unpaid' check(status in ('unpaid','pending','paid','failed','refunded')),
 provider text, provider_reference text, payment_method_reference text, refund_status text not null default 'not_applicable' check(refund_status in ('not_applicable','requested','processing','refunded','rejected')),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), reconciled_by uuid references public.profiles(id), reconciled_at timestamptz
);
create unique index payments_provider_reference_unique on public.payments(provider,provider_reference) where provider_reference is not null;
alter table public.payments enable row level security;
create policy "Booking participants read payments" on public.payments for select to authenticated using(public.is_admin() or exists(select 1 from public.bookings b left join public.professionals p on p.id=b.professional_id where b.id=booking_id and (b.customer_id=auth.uid() or p.profile_id=auth.uid())));
create policy "Administrators reconcile payments" on public.payments for all to authenticated using(public.is_admin()) with check(public.is_admin());
create table public.payment_events(
 id uuid primary key default gen_random_uuid(), payment_id uuid not null references public.payments(id) on delete cascade,
 event_type text not null, provider_event_id text, verified boolean not null default false, payload jsonb not null default '{}'::jsonb,
 occurred_at timestamptz, received_at timestamptz not null default now(), unique(provider_event_id)
);
alter table public.payment_events enable row level security;
create policy "Administrators inspect verified payment events" on public.payment_events for select to authenticated using(public.is_admin());

create table public.notifications(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 notification_type text not null, title text not null, body text not null default '', entity_type text, entity_id uuid,
 read_at timestamptz, created_at timestamptz not null default now(), expires_at timestamptz
);
create table public.notification_preferences(
 user_id uuid not null references public.profiles(id) on delete cascade, notification_type text not null,
 in_app_enabled boolean not null default true, email_enabled boolean not null default false, updated_at timestamptz not null default now(), primary key(user_id,notification_type)
);
alter table public.notifications enable row level security;alter table public.notification_preferences enable row level security;
create policy "Users read their own notifications" on public.notifications for select to authenticated using(user_id=auth.uid() or public.is_admin());
create policy "Users update own notification read state" on public.notifications for update to authenticated using(user_id=auth.uid() and public.is_active_user()) with check(user_id=auth.uid() and public.is_active_user());
create policy "Users manage notification preferences" on public.notification_preferences for all to authenticated using(user_id=auth.uid() and public.is_active_user()) with check(user_id=auth.uid() and public.is_active_user());
create index notifications_user_unread_idx on public.notifications(user_id,created_at desc) where read_at is null;
create function public.notify_booking_participants() returns trigger language plpgsql security definer set search_path=public as $$
declare professional_owner uuid; status_text text;
begin
 select profile_id into professional_owner from public.professionals where id=new.professional_id;
 status_text:=replace(new.status,'_',' ');
 if tg_op='INSERT' then
  insert into public.notifications(user_id,notification_type,title,body,entity_type,entity_id) values
   (new.customer_id,'booking','Booking request sent','Your booking request has been sent for professional review.','booking',new.id),
   (professional_owner,'booking','New booking request','A customer has requested a service booking.','booking',new.id);
 elsif new.status is distinct from old.status or new.scheduled_at is distinct from old.scheduled_at then
  if auth.uid()=new.customer_id then
   insert into public.notifications(user_id,notification_type,title,body,entity_type,entity_id) values(professional_owner,'booking','Booking updated','The customer updated a booking.','booking',new.id);
  elsif auth.uid()=professional_owner then
   insert into public.notifications(user_id,notification_type,title,body,entity_type,entity_id) values(new.customer_id,'booking','Booking updated','Your professional updated the booking: '||status_text||'.','booking',new.id);
  else
   insert into public.notifications(user_id,notification_type,title,body,entity_type,entity_id) values
    (new.customer_id,'booking','Booking updated','Your booking status is now '||status_text||'.','booking',new.id),
    (professional_owner,'booking','Booking updated','The booking status is now '||status_text||'.','booking',new.id);
  end if;
 end if;
 return new;
end $$;
create trigger marketplace_booking_notifications after insert or update of status,scheduled_at on public.bookings for each row execute function public.notify_booking_participants();

create table public.platform_settings(
 setting_key text primary key, value jsonb not null default '{}'::jsonb, updated_by uuid references public.profiles(id), updated_at timestamptz not null default now()
);
alter table public.platform_settings enable row level security;
create policy "Administrators manage platform settings" on public.platform_settings for all to authenticated using(public.is_admin()) with check(public.is_admin());
create table public.certificate_verification_events(
 id uuid primary key default gen_random_uuid(), certificate_id uuid references public.certificates(id) on delete set null,
 certificate_number_hash text not null, viewer_id uuid references public.profiles(id) on delete set null,
 credential_valid boolean not null, checked_at timestamptz not null default now()
);
alter table public.certificate_verification_events enable row level security;
create policy "Administrators inspect certificate verification events" on public.certificate_verification_events for select to authenticated using(public.is_admin());
create index certificate_verification_events_lookup_idx on public.certificate_verification_events(certificate_id,checked_at desc);
create or replace function public.verify_certificate(p_certificate_number text) returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare c public.certificates%rowtype;credential text;course_title text;valid_now boolean;
begin
 select cert.* into c from public.certificates cert where cert.certificate_number=p_certificate_number;
 if c.id is null then return null; end if;
 select title into credential from public.certifications where id=c.certification_id;
 select title into course_title from public.courses where id=c.course_id;
 valid_now:=c.revoked_at is null and (c.expires_at is null or c.expires_at>now());
 insert into public.certificate_verification_events(certificate_id,certificate_number_hash,viewer_id,credential_valid)
 values(c.id,encode(digest(c.certificate_number,'sha256'),'hex'),auth.uid(),valid_now);
 return jsonb_build_object('certificate_number',c.certificate_number,'credential',credential,'course',coalesce(course_title,'Course credential'),'issued_at',c.issued_at,'valid',valid_now,'expires_at',c.expires_at);
end $$;
revoke all on function public.verify_certificate(text) from public;
grant execute on function public.verify_certificate(text) to anon,authenticated;

-- Normalized names expose the current write model through row-security-aware views while callers migrate.
create view public.student_enrolments with (security_invoker=true) as select * from public.enrolments;
create view public.course_enrolments with (security_invoker=true) as select * from public.enrolments;
create view public.student_cohorts with (security_invoker=true) as select * from public.learning_groups;
create view public.student_cohort_members with (security_invoker=true) as select * from public.group_members;
create view public.course_progress with (security_invoker=true) as select student_id,course_id,course_version,status,progress,enrolled_at,completed_at from public.enrolments;
create view public.module_progress with (security_invoker=true) as
 select lp.student_id,m.id as module_id,m.course_id,count(*) filter(where lp.completed_at is not null)::integer as completed_lessons,
 count(l.id)::integer as total_lessons,round(100.0*count(*) filter(where lp.completed_at is not null)/nullif(count(l.id),0),1) as progress
 from public.modules m join public.lessons l on l.module_id=m.id left join public.lesson_progress lp on lp.lesson_id=l.id group by lp.student_id,m.id,m.course_id;
create view public.assessment_attempts with (security_invoker=true) as select * from public.assessment_submissions;
create view public.assessment_grades with (security_invoker=true) as select id as submission_id,assessment_id,score,feedback,reviewed_by,reviewed_at from public.assessment_submissions where reviewed_at is not null;
create view public.lesson_feedback with (security_invoker=true) as select * from public.feedback where lesson_id is not null;
create view public.module_feedback with (security_invoker=true) as select * from public.feedback where module_id is not null and lesson_id is null;
create view public.course_feedback with (security_invoker=true) as select * from public.feedback where course_id is not null and module_id is null and lesson_id is null;
create view public.consultation_threads with (security_invoker=true) as select * from public.course_consultations;
create view public.certification_recommendations with (security_invoker=true) as select id,student_id,certification_id,course_id,recommended_by,status,created_at from public.certification_applications;
create view public.professional_profiles with (security_invoker=true) as select * from public.professionals;
create view public.professional_services with (security_invoker=true) as select * from public.services;
create view public.professional_certifications with (security_invoker=true) as select * from public.professional_credentials;
create view public.service_categories with (security_invoker=true) as select * from public.marketplace_categories;
create view public.professional_portfolios with (security_invoker=true) as select * from public.professional_portfolio;
create view public.customer_conversations with (security_invoker=true) as select * from public.marketplace_conversations;
create view public.customer_messages with (security_invoker=true) as select * from public.marketplace_messages;
create view public.booking_status_history with (security_invoker=true) as select * from public.booking_history;
create view public.admin_audit_logs with (security_invoker=true) as select * from public.audit_logs;
grant select on public.student_enrolments,public.course_enrolments,public.student_cohorts,public.student_cohort_members,public.course_progress,public.module_progress,public.assessment_attempts,public.assessment_grades,public.lesson_feedback,public.module_feedback,public.course_feedback,public.consultation_threads,public.certification_recommendations,public.professional_profiles,public.professional_services,public.professional_certifications,public.service_categories,public.professional_portfolios,public.customer_conversations,public.customer_messages,public.booking_status_history,public.admin_audit_logs to authenticated;
grant select on public.professional_profiles,public.professional_services,public.professional_certifications,public.service_categories,public.professional_portfolios to anon;

create index tutor_assignments_active_course_idx on public.tutor_assignments(course_id,tutor_id) where revoked_at is null;
create index user_roles_active_lookup_idx on public.user_roles(user_id,role) where revoked_at is null;
create index course_versions_course_idx on public.course_versions(course_id,version desc);
create unique index if not exists feedback_course_once_per_student on public.feedback(student_id,course_id) where course_id is not null and module_id is null and lesson_id is null;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('course-videos','course-videos',false,524288000,array['video/mp4','video/webm']),
 ('course-resources','course-resources',false,52428800,array['application/pdf','image/jpeg','image/png','application/vnd.openxmlformats-officedocument.wordprocessingml.document']),
 ('assessment-submissions','assessment-submissions',false,20971520,array['application/pdf','image/jpeg','image/png','video/mp4']),
 ('student-reports','student-reports',false,10485760,array['application/pdf','text/csv']),
 ('certificates','certificates',false,10485760,array['application/pdf']),
 ('professional-portfolios','professional-portfolios',false,10485760,array['image/jpeg','image/png','image/webp']),
 ('profile-media','profile-media',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false;
create policy "Certificate owners and administrators read private certificates" on storage.objects for select to authenticated using(
 bucket_id='certificates' and (public.is_admin() or (storage.foldername(name))[1]=auth.uid()::text)
);
create policy "Certificate owners upload issued documents only through server" on storage.objects for insert to authenticated with check(bucket_id='certificates' and public.is_admin());
update storage.buckets set public=false where id='profile-images';
drop policy if exists "Public profile images are viewable" on storage.objects;
create policy "Public profile media only for published professionals" on storage.objects for select using(bucket_id='profile-images' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin() or exists(select 1 from public.professionals p where p.profile_photo_path=name and p.profile_state='published' and p.public_visible)));

drop policy if exists "Course members read lesson resources" on storage.objects;
create policy "Published enrolled course resources are private-readable" on storage.objects for select to authenticated using(
 bucket_id='lesson-resources' and (public.is_admin() or (storage.foldername(name))[1]=auth.uid()::text or exists(
  select 1 from public.lessons l join public.modules m on m.id=l.module_id join public.courses c on c.id=m.course_id
  where l.resource_path=name and ((c.owner_id=auth.uid()) or (l.status='published' and c.status='published' and exists(select 1 from public.enrolments e where e.course_id=c.id and e.student_id=auth.uid() and e.status in ('active','completed'))))
 ))
);
drop policy if exists "Tutor uploads lesson resources" on storage.objects;
create policy "Assigned tutors upload lesson resources" on storage.objects for insert to authenticated with check(
 bucket_id='lesson-resources' and (storage.foldername(name))[1]=auth.uid()::text and
 (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and
 (storage.foldername(name))[3] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and
 exists(select 1 from public.courses c join public.modules m on m.course_id=c.id join public.profiles p on p.id=auth.uid()
  where c.id=((storage.foldername(name))[2])::uuid and m.id=((storage.foldername(name))[3])::uuid and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active')
);
drop policy if exists "Tutors update own lesson resources" on storage.objects;
create policy "Assigned tutors update own lesson resources" on storage.objects for update to authenticated using(
 bucket_id='lesson-resources' and (storage.foldername(name))[1]=auth.uid()::text and exists(select 1 from public.courses c join public.profiles p on p.id=auth.uid() where c.owner_id=auth.uid() and (storage.foldername(name))[2]=c.id::text and p.role='tutor' and p.tutor_approved and p.account_status='active')
) with check(bucket_id='lesson-resources' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "Assigned tutors upload course assets" on storage.objects for insert to authenticated with check(
 bucket_id in ('course-videos','course-resources') and (storage.foldername(name))[1]=auth.uid()::text and
 (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and exists(
  select 1 from public.courses c join public.profiles p on p.id=auth.uid() where c.id=((storage.foldername(name))[2])::uuid and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active'
 )
);
create policy "Course assets readable by authorized learners" on storage.objects for select to authenticated using(
 bucket_id in ('course-videos','course-resources') and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin() or exists(
  select 1 from public.courses c join public.enrolments e on e.course_id=c.id where c.id=case when (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then ((storage.foldername(name))[2])::uuid else null end and c.status='published' and e.student_id=auth.uid() and e.status in ('active','completed')
 ))
);
create policy "Owners read published profile media" on storage.objects for select using(
 bucket_id='profile-media' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin() or exists(select 1 from public.professionals p where p.profile_photo_path=name and p.profile_state='published' and p.public_visible))
);
create policy "Professionals upload private profile media" on storage.objects for insert to authenticated with check(bucket_id='profile-media' and (storage.foldername(name))[1]=auth.uid()::text and public.is_active_user());
create policy "Professionals replace own profile media" on storage.objects for update to authenticated using(bucket_id='profile-media' and (storage.foldername(name))[1]=auth.uid()::text and public.is_active_user()) with check(bucket_id='profile-media' and (storage.foldername(name))[1]=auth.uid()::text and public.is_active_user());
create policy "Portfolio images visible on public profiles" on storage.objects for select using(bucket_id='professional-portfolios' and (public.is_admin() or (storage.foldername(name))[1]=auth.uid()::text or exists(select 1 from public.professional_portfolio pf join public.professionals p on p.id=pf.professional_id join public.profiles pr on pr.id=p.profile_id where pf.image_path=name and pf.consent_confirmed and p.profile_state='published' and p.public_visible and pr.account_status='active')));
create policy "Professionals upload own portfolio images" on storage.objects for insert to authenticated with check(bucket_id='professional-portfolios' and (storage.foldername(name))[1]=auth.uid()::text and public.is_active_user());
create policy "Assessment submission owner or admin downloads" on storage.objects for select to authenticated using(bucket_id='assessment-submissions' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin()));
create policy "Students upload own assessment submissions" on storage.objects for insert to authenticated with check(bucket_id='assessment-submissions' and (storage.foldername(name))[1]=auth.uid()::text and public.current_role()='student' and public.is_active_user());
create policy "Certificate owner or administrator downloads" on storage.objects for select to authenticated using(bucket_id='certificates' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin()));
create policy "Student owns private reports" on storage.objects for select to authenticated using(bucket_id='student-reports' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin()));

-- Normalized professional schedule and course certification rules.
create table public.professional_availability(
 id uuid primary key default gen_random_uuid(), professional_id uuid not null references public.professionals(id) on delete cascade,
 day_of_week smallint not null check(day_of_week between 0 and 6), starts_at time not null, ends_at time not null,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(starts_at<ends_at), unique(professional_id,day_of_week,starts_at,ends_at)
);
create index professional_availability_lookup_idx on public.professional_availability(professional_id,day_of_week,starts_at);
alter table public.professional_availability enable row level security;
create policy "Professionals manage own availability" on public.professional_availability for all to authenticated
 using(public.is_admin() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()))
 with check(public.is_admin() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()));
create policy "Public read published professional availability" on public.professional_availability for select to anon,authenticated
 using(exists(select 1 from public.professionals p where p.id=professional_id and p.profile_state='published' and p.public_visible));
create or replace function public.professional_submit_profile_photo(p_path text) returns boolean language plpgsql security definer set search_path=public as $$
declare pro_id uuid;
begin
 select id into pro_id from public.professionals where profile_id=auth.uid() for update;
 if pro_id is null or not public.is_active_user() or p_path not like auth.uid()::text||'/%' or p_path !~* '/[0-9a-f-]{36}\.(jpg|png|webp)$' then raise exception 'Profile photo upload is invalid'; end if;
 update public.professionals set profile_photo_path=p_path,status='pending',profile_state='submitted',public_visible=false,updated_at=now() where id=pro_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'PROFESSIONAL_PHOTO_SUBMITTED','professionals',pro_id,'{}'::jsonb);
 return true;
end $$;
revoke all on function public.professional_submit_profile_photo(text) from public,anon;
grant execute on function public.professional_submit_profile_photo(text) to authenticated;
create function public.sync_professional_availability() returns trigger language plpgsql security definer set search_path=public as $$
declare day_item record; slot jsonb; dow smallint;
begin
 delete from public.professional_availability where professional_id=new.id;
 if jsonb_typeof(coalesce(new.availability,'{}'::jsonb))<>'object' then raise exception 'Availability must be a weekly object'; end if;
 for day_item in select key,value from jsonb_each(coalesce(new.availability,'{}'::jsonb)) loop
  dow:=case lower(day_item.key) when 'sun' then 0 when 'mon' then 1 when 'tue' then 2 when 'wed' then 3 when 'thu' then 4 when 'fri' then 5 when 'sat' then 6 else null end;
  if dow is null or jsonb_typeof(day_item.value)<>'array' then raise exception 'Availability days must use three-letter weekday keys and arrays of time slots'; end if;
  for slot in select value from jsonb_array_elements(day_item.value) loop
   if jsonb_typeof(slot)<>'object' or nullif(slot->>'start','') is null or nullif(slot->>'end','') is null then raise exception 'Each availability slot needs start and end times'; end if;
   insert into public.professional_availability(professional_id,day_of_week,starts_at,ends_at)
   values(new.id,dow,(slot->>'start')::time,(slot->>'end')::time);
  end loop;
 end loop;
 return new;
end $$;
create trigger sync_professional_availability_json after insert or update of availability on public.professionals for each row execute function public.sync_professional_availability();
do $$ declare p record; begin for p in select id,availability from public.professionals loop
 update public.professionals set availability=p.availability where id=p.id;
end loop; end $$;

create table public.course_certification_rules(
 id uuid primary key default gen_random_uuid(), course_id uuid not null references public.courses(id) on delete cascade,
 certification_id uuid not null references public.certifications(id) on delete cascade,
 minimum_completion numeric(5,2) not null default 100 check(minimum_completion between 0 and 100),
 require_assessments boolean not null default true, require_competencies boolean not null default true,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(course_id,certification_id)
);
alter table public.course_certification_rules enable row level security;
create policy "Certification rules visible with course" on public.course_certification_rules for select to authenticated
 using(public.is_admin() or exists(select 1 from public.courses c where c.id=course_id and (c.owner_id=auth.uid() or c.status='published')));
create policy "Authorized course owners manage certification rules" on public.course_certification_rules for all to authenticated
 using(public.is_admin() or exists(select 1 from public.courses c where c.id=course_id and c.owner_id=auth.uid()))
 with check(public.is_admin() or exists(select 1 from public.courses c where c.id=course_id and c.owner_id=auth.uid()));

create index professional_credentials_certificate_idx on public.professional_credentials(certificate_id);
create index customer_favourites_customer_idx on public.customer_favourites(customer_id,created_at desc);

create or replace function public.customer_respond_reschedule(p_booking_id uuid,p_accept boolean,p_reason text default '') returns boolean
language plpgsql security definer set search_path=public as $$
declare b public.bookings%rowtype;
begin
 select * into b from public.bookings where id=p_booking_id and customer_id=auth.uid() for update;
 if b.id is null or b.status<>'rescheduling_requested' or public.current_role()<>'customer' or not public.is_active_user() then raise exception 'Rescheduling request is unavailable'; end if;
 if length(coalesce(p_reason,''))>1000 then raise exception 'Response is too long'; end if;
 if p_accept then update public.bookings set status='confirmed' where id=b.id;
 else update public.bookings set status='cancelled' where id=b.id; end if;
 update public.booking_history set notes=left(coalesce(p_reason,''),1000) where id=(select max(id) from public.booking_history where booking_id=b.id and actor_id=auth.uid());
 return true;
end $$;
revoke all on function public.customer_respond_reschedule(uuid,boolean,text) from public,anon;
grant execute on function public.customer_respond_reschedule(uuid,boolean,text) to authenticated;
