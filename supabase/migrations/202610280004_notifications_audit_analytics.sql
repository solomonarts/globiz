-- Part VI: notification workflows, value-free audit metadata, and aggregate analytics.

-- Existing generic audit rows contained full old/new records. Redact those payloads before
-- switching the trigger to store operation and changed field names only.
update public.audit_logs
set details='{"legacy_values_redacted":true}'::jsonb
where details ? 'old' or details ? 'new';

create or replace function public.write_audit_log() returns trigger
language plpgsql security definer set search_path=public as $$
declare old_row jsonb; new_row jsonb; target_id uuid; changed text[];
begin
 old_row:=case when tg_op='INSERT' then '{}'::jsonb else to_jsonb(old) end;
 new_row:=case when tg_op='DELETE' then '{}'::jsonb else to_jsonb(new) end;
 target_id:=coalesce(nullif(new_row->>'id','')::uuid,nullif(new_row->>'student_id','')::uuid,nullif(old_row->>'id','')::uuid,nullif(old_row->>'student_id','')::uuid);
 select coalesce(array_agg(k order by k),'{}'::text[]) into changed
 from (select jsonb_object_keys(old_row||new_row) k) keys
 where old_row->k is distinct from new_row->k;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),tg_table_name||'_'||lower(tg_op),tg_table_name,target_id,jsonb_build_object('operation',tg_op,'changed_fields',changed));
 if tg_op='DELETE' then return old; else return new; end if;
end $$;
revoke all on function public.write_audit_log() from public,anon,authenticated;

-- Audit access is read-only to admins. Trusted triggers and server-side workflows write logs.
revoke all on public.audit_logs from anon,authenticated;
grant select on public.audit_logs to authenticated;

create function public.enqueue_notification(p_user_id uuid,p_type text,p_title text,p_body text,p_entity_type text,p_entity_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
 if p_user_id is null or not exists(select 1 from public.profiles where id=p_user_id) then return; end if;
 if exists(select 1 from public.notification_preferences np where np.user_id=p_user_id and np.notification_type=p_type and not np.in_app_enabled) then return; end if;
 insert into public.notifications(user_id,notification_type,title,body,entity_type,entity_id)
 values(p_user_id,p_type,left(p_title,160),left(p_body,500),p_entity_type,p_entity_id);
end $$;
revoke all on function public.enqueue_notification(uuid,text,text,text,text,uuid) from public,anon,authenticated;

create function public.dispatch_platform_notification() returns trigger language plpgsql security definer set search_path=public as $$
declare course_key uuid; recipient uuid; other_party uuid; title_text text;
begin
 if tg_table_name='enrolments' then
  if tg_op='UPDATE' and old.status is distinct from new.status and new.status in ('active','withdrawn','completed') then
   perform public.enqueue_notification(new.student_id,'enrolment','Enrolment updated',case when new.status='withdrawn' then 'Your course enrolment request was not approved.' else 'Your course enrolment status is now '||new.status||'.' end,'enrolment',new.id);
  end if;
  if (exists(select 1 from public.course_certification_rules r join public.certifications cert on cert.id=r.certification_id where r.course_id=new.course_id and new.progress>=r.minimum_completion) or exists(select 1 from public.certifications cert join public.courses c on c.id=cert.course_id where c.id=new.course_id and new.progress>=c.minimum_completion)) and
   not exists(select 1 from public.notifications n where n.user_id=new.student_id and n.notification_type='certification_eligibility' and n.entity_type='course' and n.entity_id=new.course_id) and
   not exists(select 1 from public.assessments a where a.course_id=new.course_id and a.required and a.status='published' and not exists(select 1 from public.assessment_submissions s where s.assessment_id=a.id and s.student_id=new.student_id and s.reviewed_at is not null and s.score>=a.pass_score)) and
   not exists(select 1 from public.courses c cross join lateral unnest(c.required_competencies) req(id) where c.id=new.course_id and not exists(select 1 from public.competency_records cr where cr.student_id=new.student_id and cr.competency_id=req.id and cr.status in ('competent','mastered'))) then
    perform public.enqueue_notification(new.student_id,'certification_eligibility','Certification requirements met','Your learning progress meets the configured course requirements. Check your certification options.','course',new.course_id);
  end if;
 elsif tg_table_name='courses' then
  if new.status='published' and (tg_op='INSERT' or old.status is distinct from new.status) then
   for recipient in select e.student_id from public.enrolments e where e.course_id=new.id and e.status in ('active','completed') loop
    perform public.enqueue_notification(recipient,'course_availability','Course available','A course in your learning programme is now available.','course',new.id);
   end loop;
  end if;
 elsif tg_table_name='lessons' then
  if new.status='published' and (tg_op='INSERT' or old.status is distinct from new.status) then
   select course_id into course_key from public.modules where id=new.module_id;
   for recipient in select e.student_id from public.enrolments e where e.course_id=course_key and e.status in ('active','completed') loop
    perform public.enqueue_notification(recipient,'lesson_availability','New lesson available','A new lesson is available in your course.','lesson',new.id);
   end loop;
  end if;
 elsif tg_table_name='modules' then
  if exists(select 1 from public.courses c where c.id=new.course_id and c.status='published') then
   for recipient in select e.student_id from public.enrolments e where e.course_id=new.course_id and e.status in ('active','completed') loop
    perform public.enqueue_notification(recipient,'lesson_availability','New module available','New course module content is available.','module',new.id);
   end loop;
  end if;
 elsif tg_table_name='assessments' then
  if new.status='published' and (tg_op='INSERT' or old.status is distinct from new.status) then
   for recipient in select e.student_id from public.enrolments e where e.course_id=new.course_id and e.status='active' loop
    perform public.enqueue_notification(recipient,'pending_assignment','Assessment available','A new assessment is available in your course.','assessment',new.id);
   end loop;
  end if;
 elsif tg_table_name='announcements' then
  if new.status='published' and (tg_op='INSERT' or old.status is distinct from new.status) then
   if new.course_id is null then
    for recipient in select p.id from public.profiles p where p.role='student' and p.account_status='active' loop
     perform public.enqueue_notification(recipient,'announcement','New announcement','A new GlowBiz announcement is available.','announcement',new.id);
    end loop;
   else
    for recipient in select e.student_id from public.enrolments e where e.course_id=new.course_id and e.status in ('active','completed') loop
     perform public.enqueue_notification(recipient,'announcement','Course announcement','A new announcement is available in your course.','announcement',new.id);
    end loop;
   end if;
  end if;
 elsif tg_table_name='assessment_submissions' then
  if new.reviewed_at is not null and (tg_op='INSERT' or old.reviewed_at is distinct from new.reviewed_at or old.score is distinct from new.score or old.feedback is distinct from new.feedback) then
   perform public.enqueue_notification(new.student_id,'assessment_result','Assessment result available','Your assessment has been reviewed. Open your learning dashboard to view the result and feedback.','assessment_submission',new.id);
  end if;
 elsif tg_table_name='certification_applications' then
  if tg_op='INSERT' and new.status='pending_admin' then
   perform public.enqueue_notification(new.student_id,'certification_recommendation','Tutor recommendation received','A tutor has recommended you for certification review.','certification_application',new.id);
  elsif tg_op='UPDATE' and old.status is distinct from new.status then
   perform public.enqueue_notification(new.student_id,'certification','Certification status updated','Your certification application status is now '||replace(new.status,'_',' ')||'.','certification_application',new.id);
  end if;
 elsif tg_table_name='certificates' then
  if tg_op='INSERT' then
   perform public.enqueue_notification(new.student_id,'certificate','Certificate available','Your approved certificate is available in your documents.','certificate',new.id);
  elsif old.revoked_at is distinct from new.revoked_at and new.revoked_at is not null then
   perform public.enqueue_notification(new.student_id,'certificate','Certificate status updated','A certificate status has changed. Open your documents for details.','certificate',new.id);
  end if;
 elsif tg_table_name='content_reviews' then
  if tg_op='UPDATE' and old.decision is distinct from new.decision and new.submitted_by is not null then
   perform public.enqueue_notification(new.submitted_by,'content_decision','Content review updated','An administrator recorded this decision: '||replace(new.decision,'_',' ')||'.','content_review',new.id);
  end if;
 elsif tg_table_name='course_consultation_messages' then
  select student_id,tutor_id into recipient,other_party from public.course_consultations where id=new.consultation_id;
  if new.sender_id=recipient then recipient:=other_party; end if;
  perform public.enqueue_notification(recipient,'consultation_message','New consultation message','You have a new course consultation message.','consultation',new.consultation_id);
 elsif tg_table_name='marketplace_messages' then
  select c.customer_id,p.profile_id into recipient,other_party from public.marketplace_conversations c join public.professionals p on p.id=c.professional_id where c.id=new.conversation_id;
  if new.sender_id=recipient then recipient:=other_party;title_text:='New customer message';else title_text:='New professional message';end if;
  perform public.enqueue_notification(recipient,'customer_message',title_text,'You have a new marketplace message.','marketplace_conversation',new.conversation_id);
 elsif tg_table_name='professionals' then
  if tg_op='UPDATE' and old.profile_state is distinct from new.profile_state then
   perform public.enqueue_notification(new.profile_id,'professional_profile','Professional profile updated','Your professional profile status is now '||replace(new.profile_state,'_',' ')||'.','professional',new.id);
  end if;
 elsif tg_table_name='profiles' then
  if new.role='tutor' and (old.tutor_approved is distinct from new.tutor_approved or old.tutor_application_status is distinct from new.tutor_application_status) then
   perform public.enqueue_notification(new.id,'tutor_approval','Tutor application updated','Your tutor application status is now '||replace(new.tutor_application_status,'_',' ')||'.','profile',new.id);
  elsif new.role='student' and old.account_status is distinct from new.account_status then
   perform public.enqueue_notification(new.id,'account_status','Account status updated','Your student account status is now '||new.account_status||'.','profile',new.id);
  end if;
 end if;
 if tg_op='DELETE' then return old; else return new; end if;
end $$;
revoke all on function public.dispatch_platform_notification() from public,anon,authenticated;
create trigger notify_enrolment_status after insert or update of status,progress on public.enrolments for each row execute function public.dispatch_platform_notification();
create trigger notify_course_publication after insert or update of status on public.courses for each row execute function public.dispatch_platform_notification();
create trigger notify_lesson_publication after insert or update of status on public.lessons for each row execute function public.dispatch_platform_notification();
create trigger notify_module_availability after insert on public.modules for each row execute function public.dispatch_platform_notification();
create trigger notify_assessment_publication after insert or update of status on public.assessments for each row execute function public.dispatch_platform_notification();
create trigger notify_announcement_publication after insert or update of status on public.announcements for each row execute function public.dispatch_platform_notification();
create trigger notify_assessment_results after insert or update of reviewed_at,score,feedback on public.assessment_submissions for each row execute function public.dispatch_platform_notification();
create trigger notify_certification_decisions after insert or update of status on public.certification_applications for each row execute function public.dispatch_platform_notification();
create trigger notify_certificate_issue_or_revocation after insert or update of revoked_at on public.certificates for each row execute function public.dispatch_platform_notification();
create trigger notify_content_decisions after update of decision on public.content_reviews for each row execute function public.dispatch_platform_notification();
create trigger notify_consultation_messages after insert on public.course_consultation_messages for each row execute function public.dispatch_platform_notification();
create trigger notify_marketplace_messages after insert on public.marketplace_messages for each row execute function public.dispatch_platform_notification();
create trigger notify_professional_state after update of profile_state on public.professionals for each row execute function public.dispatch_platform_notification();
create trigger notify_user_approval after update of tutor_approved,tutor_application_status,account_status on public.profiles for each row execute function public.dispatch_platform_notification();

-- Additional value-free audit coverage for governance and financial transitions.
create function public.audit_field_changes() returns trigger language plpgsql security definer set search_path=public as $$
declare old_row jsonb;new_row jsonb;target_id uuid;fields text[];
begin
 old_row:=case when tg_op='INSERT' then '{}'::jsonb else to_jsonb(old) end;
 new_row:=case when tg_op='DELETE' then '{}'::jsonb else to_jsonb(new) end;
 target_id:=coalesce(nullif(new_row->>'id','')::uuid,nullif(new_row->>'student_id','')::uuid,nullif(old_row->>'id','')::uuid,nullif(old_row->>'student_id','')::uuid);
 select coalesce(array_agg(k order by k),'{}'::text[]) into fields from (select jsonb_object_keys(old_row||new_row) k) q where old_row->k is distinct from new_row->k;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),tg_table_name||'_'||lower(tg_op),tg_table_name,target_id,jsonb_build_object('operation',tg_op,'changed_fields',fields));
 if tg_op='DELETE' then return old; else return new; end if;
end $$;
revoke all on function public.audit_field_changes() from public,anon,authenticated;
create trigger audit_tutor_permission_changes after update of tutor_approved,tutor_application_status,account_status on public.profiles for each row when(old.tutor_approved is distinct from new.tutor_approved or old.tutor_application_status is distinct from new.tutor_application_status or old.account_status is distinct from new.account_status) execute function public.audit_field_changes();
create trigger audit_course_publication after update of status on public.courses for each row when(old.status is distinct from new.status) execute function public.audit_field_changes();
create trigger audit_lesson_publication after update of status on public.lessons for each row when(old.status is distinct from new.status) execute function public.audit_field_changes();
create trigger audit_assessment_publication after update of status on public.assessments for each row when(old.status is distinct from new.status) execute function public.audit_field_changes();
create trigger audit_content_review_decisions after update of decision,reviewer_id,reason,reviewed_at on public.content_reviews for each row when(old.decision is distinct from new.decision or old.reviewer_id is distinct from new.reviewer_id or old.reason is distinct from new.reason or old.reviewed_at is distinct from new.reviewed_at) execute function public.audit_field_changes();
create trigger audit_professional_verification after update of status,profile_state,public_visible on public.professionals for each row when(old.status is distinct from new.status or old.profile_state is distinct from new.profile_state or old.public_visible is distinct from new.public_visible) execute function public.audit_field_changes();
create trigger audit_payment_changes after insert or update of status,refund_status,reconciled_by,reconciled_at on public.payments for each row execute function public.audit_field_changes();
create trigger audit_payment_event_verification after insert or update of verified on public.payment_events for each row execute function public.audit_field_changes();
create trigger audit_professional_credentials after insert or update or delete on public.professional_credentials for each row execute function public.audit_field_changes();

create or replace function public.mark_notification_read(p_notification_id uuid) returns boolean language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or not public.is_active_user() then raise exception 'Active account required'; end if;
 update public.notifications set read_at=coalesce(read_at,now()) where id=p_notification_id and user_id=auth.uid();
 return found;
end $$;
revoke all on function public.mark_notification_read(uuid) from public,anon;
grant execute on function public.mark_notification_read(uuid) to authenticated;
create or replace function public.mark_all_notifications_read() returns integer language plpgsql security definer set search_path=public as $$
declare n integer;
begin
 if auth.uid() is null or not public.is_active_user() then raise exception 'Active account required'; end if;
 update public.notifications set read_at=now() where user_id=auth.uid() and read_at is null;
 get diagnostics n=row_count;return n;
end $$;
revoke all on function public.mark_all_notifications_read() from public,anon;
grant execute on function public.mark_all_notifications_read() to authenticated;
revoke update on public.notifications from anon,authenticated;
grant update(read_at) on public.notifications to authenticated;

create or replace function public.save_notification_preference(p_type text,p_in_app boolean,p_email boolean) returns boolean language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or not public.is_active_user() or p_type not in ('enrolment','account_status','tutor_approval','course_availability','lesson_availability','assessment_result','pending_assignment','announcement','certification','certification_recommendation','certification_eligibility','certificate','content_decision','consultation_message','booking','customer_message','professional_profile') then raise exception 'Invalid notification preference'; end if;
 if coalesce(p_email,false) then raise exception 'Email notifications are not configured'; end if;
 insert into public.notification_preferences(user_id,notification_type,in_app_enabled,email_enabled,updated_at)
 values(auth.uid(),p_type,coalesce(p_in_app,true),coalesce(p_email,false),now()) on conflict(user_id,notification_type) do update set in_app_enabled=excluded.in_app_enabled,email_enabled=excluded.email_enabled,updated_at=now();
 return true;
end $$;
revoke all on function public.save_notification_preference(text,boolean,boolean) from public,anon;
grant execute on function public.save_notification_preference(text,boolean,boolean) to authenticated;
revoke insert,update,delete on public.notification_preferences from anon,authenticated;
grant select on public.notification_preferences to authenticated;

-- Reuse preference-aware notification insertion for the existing booking workflow.
create or replace function public.notify_booking_participants() returns trigger language plpgsql security definer set search_path=public as $$
declare professional_owner uuid; status_text text;
begin
 select profile_id into professional_owner from public.professionals where id=new.professional_id;
 status_text:=replace(new.status,'_',' ');
 if tg_op='INSERT' then
  perform public.enqueue_notification(new.customer_id,'booking','Booking request sent','Your booking request has been sent for professional review.','booking',new.id);
  perform public.enqueue_notification(professional_owner,'booking','New booking request','A customer has requested a service booking.','booking',new.id);
 elsif new.status is distinct from old.status or new.scheduled_at is distinct from old.scheduled_at then
  if auth.uid()=new.customer_id then perform public.enqueue_notification(professional_owner,'booking','Booking updated','The customer updated a booking.','booking',new.id);
  elsif auth.uid()=professional_owner and new.status='completed' then perform public.enqueue_notification(new.customer_id,'booking','Booking complete','Your service booking is complete. You can now leave a review.','booking',new.id);
  elsif auth.uid()=professional_owner then perform public.enqueue_notification(new.customer_id,'booking','Booking updated','Your professional updated the booking: '||status_text||'.','booking',new.id);
  else
   perform public.enqueue_notification(new.customer_id,'booking','Booking updated','Your booking status is now '||status_text||'.','booking',new.id);
   perform public.enqueue_notification(professional_owner,'booking','Booking updated','The booking status is now '||status_text||'.','booking',new.id);
  end if;
 end if;
 return new;
end $$;
revoke all on function public.notify_booking_participants() from public,anon,authenticated;

create or replace function public.log_sensitive_admin_access(p_entity_type text,p_entity_id uuid,p_reason text default '') returns boolean language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() or p_entity_type not in ('student_report','student_record','audit_log') or length(coalesce(p_reason,''))>300 then raise exception 'Authorized administrative access required'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'SENSITIVE_ACCESS',p_entity_type,p_entity_id,jsonb_build_object('reason',left(coalesce(p_reason,''),300)));
 return true;
end $$;
revoke all on function public.log_sensitive_admin_access(text,uuid,text) from public,anon;
grant execute on function public.log_sensitive_admin_access(text,uuid,text) to authenticated;

create function public.audit_booking_status_change() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.status is distinct from old.status or new.scheduled_at is distinct from old.scheduled_at or new.agreed_price is distinct from old.agreed_price then
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'BOOKING_UPDATED','bookings',new.id,jsonb_build_object('old_status',old.status,'new_status',new.status,'time_changed',old.scheduled_at is distinct from new.scheduled_at,'price_changed',old.agreed_price is distinct from new.agreed_price));
 end if;
 return new;
end $$;
revoke all on function public.audit_booking_status_change() from public,anon,authenticated;
create trigger audit_booking_status after update on public.bookings for each row execute function public.audit_booking_status_change();

-- Admin-only analytics views. Percentages exclude unreviewed/missing scores; averages are NULL
-- for empty samples instead of implying zero performance.
create view public.analytics_course_performance with (security_invoker=true) as
select c.id course_id,c.title course_title,c.programme_id,c.owner_id tutor_id,c.status,
 x.enrolments,x.completed,x.active,x.pending,x.average_progress,
 r.feedback_count,r.average_rating
from public.courses c
cross join lateral(select count(*) enrolments,count(*) filter(where e.status='completed') completed,count(*) filter(where e.status='active') active,count(*) filter(where e.status='pending') pending,round(avg(e.progress) filter(where e.status in ('active','completed'))::numeric,1) average_progress from public.enrolments e where e.course_id=c.id) x
cross join lateral(select count(*) feedback_count,round(avg(f.rating)::numeric,2) average_rating from public.feedback f where f.course_id=c.id and f.status='approved') r
where public.is_admin();
create view public.analytics_programme_performance with (security_invoker=true) as
select p.id programme_id,p.title programme_title,count(distinct c.id) course_count,count(distinct e.id) enrolments,
 count(distinct e.id) filter(where e.status='completed') completed_enrolments,
 round(avg(e.progress) filter(where e.status in ('active','completed'))::numeric,1) average_progress
from public.programmes p left join public.courses c on c.programme_id=p.id left join public.enrolments e on e.course_id=c.id
where public.is_admin() group by p.id,p.title;
create view public.analytics_module_performance with (security_invoker=true) as
select c.programme_id,c.id course_id,c.title course_title,m.id module_id,m.title module_title,
 count(distinct l.id) lesson_count,count(distinct lp.id) filter(where lp.completed_at is not null) lesson_completions,
 round(100.0*count(distinct lp.id) filter(where lp.completed_at is not null)/nullif(count(distinct e.id)*count(distinct l.id),0),1) completion_records_percent
from public.modules m join public.courses c on c.id=m.course_id left join public.lessons l on l.module_id=m.id left join public.lesson_progress lp on lp.lesson_id=l.id left join public.enrolments e on e.course_id=c.id and e.status in ('active','completed')
where public.is_admin() group by c.programme_id,c.id,c.title,m.id,m.title;
create view public.analytics_assessment_outcomes with (security_invoker=true) as
select c.programme_id,c.id course_id,c.title course_title,a.id assessment_id,a.title assessment_title,
 count(s.id) attempts,count(s.id) filter(where s.reviewed_at is not null) reviewed,
 count(s.id) filter(where s.reviewed_at is not null and s.score>=a.pass_score) passed,
 count(s.id) filter(where s.reviewed_at is not null and s.score<a.pass_score) below_pass,
 round(100.0*count(s.id) filter(where s.reviewed_at is not null and s.score>=a.pass_score)/nullif(count(s.id) filter(where s.reviewed_at is not null and s.score is not null),0),1) pass_rate_percent,
 round(avg(s.score) filter(where s.reviewed_at is not null)::numeric,1) average_reviewed_score
from public.assessments a join public.courses c on c.id=a.course_id left join public.assessment_submissions s on s.assessment_id=a.id
where public.is_admin() group by c.programme_id,c.id,c.title,a.id,a.title;
create view public.analytics_certification_outcomes with (security_invoker=true) as
select c.id course_id,c.title course_title,cert.id certification_id,cert.title certification_title,count(*) applications,count(*) filter(where ca.status='approved') approved_count,count(*) filter(where ca.status='rejected') rejected_count,
 count(*) filter(where ca.status in ('pending_tutor','pending_admin')) pending_count,count(*) filter(where ca.status='changes_requested') changes_requested_count
from public.certification_applications ca left join public.courses c on c.id=ca.course_id join public.certifications cert on cert.id=ca.certification_id where public.is_admin() group by c.id,c.title,cert.id,cert.title;
create view public.analytics_tutor_engagement with (security_invoker=true) as
select t.id tutor_id,t.full_name tutor_name,count(distinct c.id) assigned_courses,
 count(distinct c.id) filter(where c.status='published') published_courses,
 (select count(*) from public.assessment_submissions s join public.assessments a on a.id=s.assessment_id join public.courses c2 on c2.id=a.course_id where c2.owner_id=t.id and s.reviewed_at is not null) graded_submissions,
 (select count(*) from public.content_reviews cr where cr.submitted_by=t.id) content_submissions,
 (select count(*) from public.course_consultations cc where cc.tutor_id=t.id) consultations
from public.profiles t left join public.courses c on c.owner_id=t.id where public.is_admin() and t.role='tutor' group by t.id,t.full_name;
create view public.analytics_feedback_trends with (security_invoker=true) as
select date_trunc('month',f.created_at)::date as "month",c.title course_title,m.title module_title,count(*) rating_count,round(avg(f.rating)::numeric,2) average_rating
from public.feedback f left join public.courses c on c.id=f.course_id left join public.modules m on m.id=f.module_id where public.is_admin() and f.status='approved' and f.rating is not null group by date_trunc('month',f.created_at)::date,c.id,c.title,m.id,m.title;
create view public.analytics_cohort_performance with (security_invoker=true) as
select g.id cohort_id,g.name cohort_name,g.programme_id,g.course_id,count(distinct gm.student_id) students,
 count(distinct e.student_id) filter(where e.status='completed') completed_students,round(avg(e.progress) filter(where e.status in ('active','completed'))::numeric,1) average_progress
from public.learning_groups g left join public.group_members gm on gm.group_id=g.id left join public.enrolments e on e.student_id=gm.student_id and ((g.course_id is not null and e.course_id=g.course_id) or (g.course_id is null and (g.programme_id is null or exists(select 1 from public.courses gc where gc.id=e.course_id and gc.programme_id=g.programme_id))))
where public.is_admin() group by g.id,g.name,g.programme_id,g.course_id;
create view public.analytics_marketplace_activity with (security_invoker=true) as
select date_trunc('month',b.created_at)::date as "month",p.id professional_id,coalesce(p.business_name,p.display_name) professional_name,count(*) booking_requests,
 count(*) filter(where b.status in ('confirmed','completed')) confirmed_or_completed,
 count(*) filter(where b.status='completed') completed,
 count(*) filter(where b.status='cancelled') cancelled,
 round(100.0*count(*) filter(where b.status in ('confirmed','completed'))/nullif(count(*),0),1) booking_conversion_percent,
 round(avg(b.agreed_price)::numeric,2) average_agreed_price
from public.bookings b join public.professionals p on p.id=b.professional_id where public.is_admin() group by date_trunc('month',b.created_at)::date,p.id,coalesce(p.business_name,p.display_name);
create view public.analytics_daily_activity with (security_invoker=true) as
with events as (
 select e.created_at::date as "day",e.course_id,'enrolment'::text metric from public.enrolments e where e.status in ('active','completed')
 union all select lp.updated_at::date,m.course_id,'lesson_completion' from public.lesson_progress lp join public.lessons l on l.id=lp.lesson_id join public.modules m on m.id=l.module_id where lp.completed_at is not null
 union all select s.submitted_at::date,a.course_id,'assessment_submission' from public.assessment_submissions s join public.assessments a on a.id=s.assessment_id
)
select e."day",e.course_id,c.title course_title,e.metric,count(*) event_count from events e left join public.courses c on c.id=e.course_id where public.is_admin() group by e."day",e.course_id,c.title,e.metric;
grant select on public.analytics_course_performance,public.analytics_programme_performance,public.analytics_module_performance,public.analytics_assessment_outcomes,public.analytics_certification_outcomes,public.analytics_tutor_engagement,public.analytics_feedback_trends,public.analytics_cohort_performance,public.analytics_marketplace_activity,public.analytics_daily_activity to authenticated;

create index if not exists assessment_submissions_reviewed_idx on public.assessment_submissions(reviewed_at desc) where reviewed_at is not null;
create index if not exists assessment_submissions_period_course_idx on public.assessment_submissions(submitted_at desc,assessment_id);
create index if not exists lesson_progress_completion_period_idx on public.lesson_progress(updated_at desc,lesson_id) where completed_at is not null;
create index if not exists enrolments_period_status_course_idx on public.enrolments(created_at desc,course_id,status);
create index if not exists bookings_period_professional_status_idx on public.bookings(created_at desc,professional_id,status);
create index if not exists feedback_approved_period_course_idx on public.feedback(created_at desc,course_id,module_id) where status='approved';
create index if not exists course_consultation_messages_unread_idx on public.course_consultation_messages(consultation_id,created_at desc) where read_at is null;
create index if not exists marketplace_messages_unread_idx on public.marketplace_messages(conversation_id,created_at desc) where read_at is null;
create index if not exists notifications_entity_idx on public.notifications(entity_type,entity_id,created_at desc);
