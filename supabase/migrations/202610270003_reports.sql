alter table public.enrolments add column completed_at timestamptz;
update public.enrolments set completed_at=coalesce(reviewed_at,created_at) where status='completed' and completed_at is null;
create index enrolments_completed_at_idx on public.enrolments(completed_at desc) where completed_at is not null;

create function public.set_enrolment_completion_time() returns trigger language plpgsql set search_path=public
as $$ begin
 if new.status='completed' and old.status is distinct from 'completed' then new.completed_at:=coalesce(new.completed_at,now());
 elsif new.status<>'completed' then new.completed_at:=null; end if;
 return new;
end $$;
create trigger enrolment_completion_time before insert or update on public.enrolments for each row execute procedure public.set_enrolment_completion_time();

create function public.admin_generate_report(p_type text,p_filters jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path=public
as $$
declare
  start_date date := nullif(p_filters->>'start_date','')::date;
  end_date date := nullif(p_filters->>'end_date','')::date;
  programme_filter uuid := nullif(p_filters->>'programme_id','')::uuid;
  course_filter uuid := nullif(p_filters->>'course_id','')::uuid;
  module_filter uuid := nullif(p_filters->>'module_id','')::uuid;
  tutor_filter uuid := nullif(p_filters->>'tutor_id','')::uuid;
  student_filter uuid := nullif(p_filters->>'student_id','')::uuid;
  status_filter text := nullif(p_filters->>'status','');
  cols text[];
  rows jsonb := '[]'::jsonb;
  student_report jsonb;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if end_date is not null and start_date is not null and end_date<start_date then raise exception 'End date must be after start date'; end if;

  if p_type='student_progress' then
    if student_filter is null then raise exception 'Choose a student for an individual progress report'; end if;
    student_report:=public.admin_student_report(student_filter);
    if student_report->'profile' is null or student_report->'profile'='null'::jsonb then raise exception 'Student record was not found'; end if;
    cols:=array['Section','Item','Programme or course','Status','Progress or score','Date','Details'];
    select coalesce(jsonb_agg(item order by sort_key),'[]'::jsonb) into rows from (
      select 1 sort_key,jsonb_build_array('Enrolment',e->>'course_title',coalesce(e->>'programme_title',''),e->>'status',coalesce(e->>'progress','')||'%',e->>'created_at','') item
      from jsonb_array_elements(student_report->'enrolments') e
      where (start_date is null or (e->>'created_at')::timestamptz>=start_date::timestamptz) and (end_date is null or (e->>'created_at')::timestamptz<(end_date+1)::timestamptz)
      union all
      select 2,jsonb_build_array('Assessment',a->>'assessment_title','',case when a->>'score' is null or a->>'score'='null' then 'Pending' else 'Reviewed' end,coalesce(a->>'score','Pending'),a->>'submitted_at',coalesce(a->>'feedback',''))
      from jsonb_array_elements(student_report->'assessments') a
      where (start_date is null or (a->>'submitted_at')::timestamptz>=start_date::timestamptz) and (end_date is null or (a->>'submitted_at')::timestamptz<(end_date+1)::timestamptz)
      union all
      select 3,jsonb_build_array('Certificate',c->>'certification','',case when c->>'revoked_at' is null or c->>'revoked_at'='null' then 'Issued' else 'Revoked' end,c->>'certificate_number',c->>'issued_at','')
      from jsonb_array_elements(student_report->'certificates') c
      where (start_date is null or (c->>'issued_at')::timestamptz>=start_date::timestamptz) and (end_date is null or (c->>'issued_at')::timestamptz<(end_date+1)::timestamptz)
      union all
      select 4,jsonb_build_array('Competency',c->>'competency','',c->>'status','',c->>'assessed_at',coalesce(c->>'evidence',''))
      from jsonb_array_elements(student_report->'competencies') c
      where (start_date is null or (c->>'assessed_at')::timestamptz>=start_date::timestamptz) and (end_date is null or (c->>'assessed_at')::timestamptz<(end_date+1)::timestamptz)
    ) q;

  elsif p_type='programme_enrolments' then
    cols:=array['Student ID','Student','Email','Programme','Course','Status','Progress','Enrolled'];
    select coalesce(jsonb_agg(jsonb_build_array(p.student_number,p.full_name,p.email,pr.title,c.title,e.status,e.progress,e.created_at) order by e.created_at desc),'[]'::jsonb) into rows
    from public.enrolments e join public.profiles p on p.id=e.student_id join public.courses c on c.id=e.course_id left join public.programmes pr on pr.id=c.programme_id
    where (programme_filter is null or pr.id=programme_filter) and (course_filter is null or c.id=course_filter) and (student_filter is null or p.id=student_filter) and (tutor_filter is null or c.owner_id=tutor_filter)
      and (status_filter is null or e.status=status_filter) and (start_date is null or e.created_at>=start_date::timestamptz) and (end_date is null or e.created_at<(end_date+1)::timestamptz);

  elsif p_type='course_performance' then
    cols:=array['Programme','Course','Tutor','Status','Enrolments','Completed','Average progress','Average rating'];
    select coalesce(jsonb_agg(jsonb_build_array(pr.title,c.title,t.full_name,c.status,x.enrolments,x.completed,x.progress,r.rating) order by c.title),'[]'::jsonb) into rows
    from public.courses c left join public.programmes pr on pr.id=c.programme_id join public.profiles t on t.id=c.owner_id
    cross join lateral (select count(*) enrolments,count(*) filter(where e.status='completed') completed,round(avg(e.progress)::numeric,1) progress from public.enrolments e where e.course_id=c.id and (start_date is null or e.created_at>=start_date::timestamptz) and (end_date is null or e.created_at<(end_date+1)::timestamptz) and (student_filter is null or e.student_id=student_filter)) x
    cross join lateral (select round(avg(f.rating)::numeric,2) rating from public.feedback f where f.course_id=c.id and f.status='approved' and (start_date is null or f.created_at>=start_date::timestamptz) and (end_date is null or f.created_at<(end_date+1)::timestamptz)) r
    where (programme_filter is null or pr.id=programme_filter) and (course_filter is null or c.id=course_filter) and (tutor_filter is null or c.owner_id=tutor_filter) and (status_filter is null or c.status::text=status_filter);

  elsif p_type='module_performance' then
    cols:=array['Programme','Course','Module','Tutor','Lessons','Completed lesson records','Rating'];
    select coalesce(jsonb_agg(jsonb_build_array(pr.title,c.title,m.title,t.full_name,x.lessons,x.completions,r.rating) order by c.title,m.position),'[]'::jsonb) into rows
    from public.modules m join public.courses c on c.id=m.course_id left join public.programmes pr on pr.id=c.programme_id join public.profiles t on t.id=c.owner_id
    cross join lateral (select count(distinct l.id) lessons,count(lp.id) filter(where lp.completed_at is not null) completions from public.lessons l left join public.lesson_progress lp on lp.lesson_id=l.id and (student_filter is null or lp.student_id=student_filter) and (start_date is null or lp.updated_at>=start_date::timestamptz) and (end_date is null or lp.updated_at<(end_date+1)::timestamptz) where l.module_id=m.id) x
    cross join lateral (select round(avg(f.rating)::numeric,2) rating from public.feedback f where f.module_id=m.id and f.status='approved' and (start_date is null or f.created_at>=start_date::timestamptz) and (end_date is null or f.created_at<(end_date+1)::timestamptz)) r
    where (programme_filter is null or pr.id=programme_filter) and (course_filter is null or c.id=course_filter) and (module_filter is null or m.id=module_filter) and (tutor_filter is null or c.owner_id=tutor_filter) and (status_filter is null or c.status::text=status_filter);

  elsif p_type='assessment_outcomes' then
    cols:=array['Student ID','Student','Programme','Course','Module','Assessment','Score','Outcome','Submitted','Reviewed'];
    select coalesce(jsonb_agg(jsonb_build_array(p.student_number,p.full_name,pr.title,c.title,m.title,a.title,s.score,case when s.score is null then 'Pending' when s.score>=a.pass_score then 'Pass' else 'Needs reassessment' end,s.submitted_at,s.reviewed_at) order by s.submitted_at desc),'[]'::jsonb) into rows
    from public.assessment_submissions s join public.profiles p on p.id=s.student_id join public.assessments a on a.id=s.assessment_id join public.courses c on c.id=a.course_id left join public.programmes pr on pr.id=c.programme_id left join public.modules m on m.id=a.module_id
    where (programme_filter is null or pr.id=programme_filter) and (course_filter is null or c.id=course_filter) and (module_filter is null or m.id=module_filter) and (tutor_filter is null or c.owner_id=tutor_filter) and (student_filter is null or p.id=student_filter) and (status_filter is null or (case when s.reviewed_at is null then 'pending' when s.score>=a.pass_score then 'pass' else 'reassessment' end)=status_filter) and (start_date is null or s.submitted_at>=start_date::timestamptz) and (end_date is null or s.submitted_at<(end_date+1)::timestamptz);

  elsif p_type='certification_eligibility' then
    cols:=array['Student ID','Student','Programme','Course','Progress','Required completion','Assessment checks','Competency checks','Recommendation','Last activity'];
    select coalesce(jsonb_agg(jsonb_build_array(p.student_number,p.full_name,pr.title,c.title,e.progress,c.minimum_completion,case when exists(select 1 from public.assessments a where a.course_id=c.id and a.status='published' and not exists(select 1 from public.assessment_submissions s where s.assessment_id=a.id and s.student_id=p.id and s.score>=a.pass_score)) then 'Incomplete' else 'Passed' end,case when exists(select 1 from unnest(c.required_competencies) req(id) where not exists(select 1 from public.competency_records cr where cr.student_id=p.id and cr.competency_id=req.id and cr.status in ('competent','mastered'))) then 'Incomplete' else 'Met' end,coalesce(ca.status,case when e.progress<c.minimum_completion then 'In progress' when exists(select 1 from public.assessments a where a.course_id=c.id and a.status='published' and not exists(select 1 from public.assessment_submissions s where s.assessment_id=a.id and s.student_id=p.id and s.reviewed_at is not null and s.score>=a.pass_score)) then 'Assessment requirements outstanding' when exists(select 1 from unnest(c.required_competencies) req(id) where not exists(select 1 from public.competency_records cr where cr.student_id=p.id and cr.competency_id=req.id and cr.status in ('competent','mastered'))) then 'Competency requirements outstanding' else 'Eligible for tutor review' end),e.created_at) order by p.full_name),'[]'::jsonb) into rows
    from public.enrolments e join public.profiles p on p.id=e.student_id join public.courses c on c.id=e.course_id left join public.programmes pr on pr.id=c.programme_id left join lateral (select status from public.certification_applications ca where ca.student_id=p.id and ca.course_id=c.id order by created_at desc limit 1) ca on true
    where (programme_filter is null or pr.id=programme_filter) and (course_filter is null or c.id=course_filter) and (student_filter is null or p.id=student_filter) and (tutor_filter is null or c.owner_id=tutor_filter) and (status_filter is null or e.status=status_filter) and (start_date is null or e.created_at>=start_date::timestamptz) and (end_date is null or e.created_at<(end_date+1)::timestamptz);

  elsif p_type='certificates_issued' then
    cols:=array['Certificate ID','Student ID','Student','Programme','Course','Credential','Curriculum version','Issued','Status','Revocation reason'];
    select coalesce(jsonb_agg(jsonb_build_array(cert.certificate_number,p.student_number,p.full_name,pr.title,c.title,level.name,cert.curriculum_version,cert.issued_at,case when cert.revoked_at is null then 'Valid' else 'Revoked' end,cert.revocation_reason) order by cert.issued_at desc),'[]'::jsonb) into rows
    from public.certificates cert join public.profiles p on p.id=cert.student_id join public.certifications cr on cr.id=cert.certification_id left join public.certification_levels level on level.id=cert.certification_level_id left join public.courses c on c.id=cert.course_id left join public.programmes pr on pr.id=c.programme_id
    where (programme_filter is null or pr.id=programme_filter) and (course_filter is null or c.id=course_filter) and (student_filter is null or p.id=student_filter) and (status_filter is null or (case when cert.revoked_at is null then 'valid' else 'revoked' end)=status_filter) and (start_date is null or cert.issued_at>=start_date::timestamptz) and (end_date is null or cert.issued_at<(end_date+1)::timestamptz);

  elsif p_type='tutor_engagement' then
    cols:=array['Tutor','Email','Application status','Assigned courses','Published courses','Modules','Lessons','Assessment reviews'];
    select coalesce(jsonb_agg(jsonb_build_array(p.full_name,p.email,p.tutor_application_status,x.courses,x.published,x.modules,x.lessons,q.reviews) order by p.full_name),'[]'::jsonb) into rows
    from public.profiles p cross join lateral (select count(distinct c.id) courses,count(distinct c.id) filter(where c.status='published') published,count(distinct m.id) modules,count(distinct l.id) lessons from public.courses c left join public.modules m on m.course_id=c.id left join public.lessons l on l.module_id=m.id where c.owner_id=p.id and (course_filter is null or c.id=course_filter) and (programme_filter is null or c.programme_id=programme_filter)) x
    cross join lateral (select count(s.id) reviews from public.assessment_submissions s join public.assessments a on a.id=s.assessment_id join public.courses c on c.id=a.course_id where c.owner_id=p.id and s.reviewed_at is not null and (start_date is null or s.reviewed_at>=start_date::timestamptz) and (end_date is null or s.reviewed_at<(end_date+1)::timestamptz)) q
    where p.role='tutor' and (tutor_filter is null or p.id=tutor_filter) and (status_filter is null or p.tutor_application_status=status_filter);

  elsif p_type='content_approvals' then
    cols:=array['Content type','Content ID','State','Submitted by','Reviewer','Decision reason','Version','Date'];
    select coalesce(jsonb_agg(jsonb_build_array(cr.entity_type,cr.entity_id,cr.decision,submitter.full_name,reviewer.full_name,cr.reason,cr.version,coalesce(cr.reviewed_at,cr.created_at)) order by cr.created_at desc),'[]'::jsonb) into rows
    from public.content_reviews cr left join public.profiles submitter on submitter.id=cr.submitted_by left join public.profiles reviewer on reviewer.id=cr.reviewer_id
    where (tutor_filter is null or cr.submitted_by=tutor_filter) and (status_filter is null or cr.decision=status_filter) and (start_date is null or coalesce(cr.reviewed_at,cr.created_at)>=start_date::timestamptz) and (end_date is null or coalesce(cr.reviewed_at,cr.created_at)<(end_date+1)::timestamptz);

  elsif p_type='feedback_ratings' then
    cols:=array['Rating','Review','Course','Module','Lesson','Anonymous','Status','Resolution','Flagged','Submitted'];
    select coalesce(jsonb_agg(jsonb_build_array(f.rating,coalesce(f.redacted_body,f.body),c.title,m.title,l.title,f.anonymous,f.status,f.resolution_status,f.flagged,f.created_at) order by f.created_at desc),'[]'::jsonb) into rows
    from public.feedback f left join public.courses c on c.id=f.course_id left join public.modules m on m.id=f.module_id left join public.lessons l on l.id=f.lesson_id left join public.profiles tutor on tutor.id=f.assigned_tutor_id
    where (course_filter is null or c.id=course_filter) and (module_filter is null or m.id=module_filter) and (tutor_filter is null or coalesce(f.assigned_tutor_id,c.owner_id)=tutor_filter) and (student_filter is null or f.student_id=student_filter) and (status_filter is null or f.status=status_filter) and (start_date is null or f.created_at>=start_date::timestamptz) and (end_date is null or f.created_at<(end_date+1)::timestamptz);

  elsif p_type='completion_trends' then
    cols:=array['Month','Programme','Course','Completed enrolments','Average completion'];
    select coalesce(jsonb_agg(jsonb_build_array(to_char(date_trunc('month',e.completed_at),'YYYY-MM'),pr.title,c.title,count(*),round(avg(e.progress)::numeric,1)) order by date_trunc('month',e.completed_at) desc,c.title),'[]'::jsonb) into rows
    from public.enrolments e join public.courses c on c.id=e.course_id left join public.programmes pr on pr.id=c.programme_id
    where e.status='completed' and e.completed_at is not null and (programme_filter is null or pr.id=programme_filter) and (course_filter is null or c.id=course_filter) and (tutor_filter is null or c.owner_id=tutor_filter) and (student_filter is null or e.student_id=student_filter) and (start_date is null or e.completed_at>=start_date::timestamptz) and (end_date is null or e.completed_at<(end_date+1)::timestamptz)
    group by date_trunc('month',e.completed_at),pr.title,c.title;

  elsif p_type='marketplace_activity' then
    cols:=array['Booking ID','Customer','Professional','Category','Service','Scheduled','Status','Requested'];
    select coalesce(jsonb_agg(jsonb_build_array(b.id,customer.full_name,pro.display_name,pro.category,service.title,b.scheduled_at,b.status,b.created_at) order by b.scheduled_at desc),'[]'::jsonb) into rows
    from public.bookings b join public.profiles customer on customer.id=b.customer_id join public.professionals pro on pro.id=b.professional_id left join public.services service on service.id=b.service_id
    where (tutor_filter is null or pro.profile_id=tutor_filter) and (status_filter is null or b.status=status_filter) and (start_date is null or b.created_at>=start_date::timestamptz) and (end_date is null or b.created_at<(end_date+1)::timestamptz);

  elsif p_type='platform_summary' then
    cols:=array['Metric','Value'];
    select coalesce(jsonb_agg(jsonb_build_array(metric,value)),'[]'::jsonb) into rows from (values
      ('Registered students',(select count(*)::text from public.profiles where role='student')),
      ('Active students',(select count(*)::text from public.profiles where role='student' and account_status='active')),
      ('Pending student approvals',(select count(*)::text from public.profiles where role='student' and account_status='pending')),
      ('Approved tutors',(select count(*)::text from public.profiles where role='tutor' and tutor_approved and account_status='active')),
      ('Published courses',(select count(*)::text from public.courses where status='published')),
      ('Enrolments',(select count(*)::text from public.enrolments where start_date is null or created_at>=start_date::timestamptz)),
      ('Certificates issued',(select count(*)::text from public.certificates where revoked_at is null and (start_date is null or issued_at>=start_date::timestamptz))),
      ('Pending feedback',(select count(*)::text from public.feedback where status='pending')),
      ('Active bookings',(select count(*)::text from public.bookings where status in ('requested','confirmed') and (start_date is null or created_at>=start_date::timestamptz)))
    ) s(metric,value);

  else raise exception 'Unknown report type';
  end if;
  return jsonb_build_object('type',p_type,'title',replace(initcap(replace(p_type,'_',' ')),'Id','ID'),'columns',to_jsonb(cols),'rows',rows,'filters',p_filters,'issued_at',now());
end $$;
revoke all on function public.admin_generate_report(text,jsonb) from public,anon;
grant execute on function public.admin_generate_report(text,jsonb) to authenticated;
