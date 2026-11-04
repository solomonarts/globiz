-- Create an immutable administrator-approved curriculum snapshot atomically.
drop policy if exists "Course versions readable to members" on public.course_versions;
create policy "Course versions readable to administrators and assigned tutors"
on public.course_versions for select to authenticated using(
 public.is_admin() or exists(
  select 1 from public.courses c
  where c.id=course_id and c.owner_id=auth.uid()
   and public.current_role()='tutor' and public.is_active_user()
   and exists(select 1 from public.tutor_assignments ta where ta.course_id=c.id and ta.tutor_id=auth.uid() and ta.revoked_at is null)
 )
);

create or replace function public.set_enrolment_curriculum_version() returns trigger
language plpgsql security definer set search_path=public as $$
declare active_version integer;
begin
 select current_version into active_version from public.courses where id=new.course_id;
 if active_version is null then raise exception 'Course not found'; end if;
 new.course_version:=active_version;
 return new;
end $$;
revoke all on function public.set_enrolment_curriculum_version() from public,anon,authenticated;
drop trigger if exists enrolments_set_curriculum_version on public.enrolments;
create trigger enrolments_set_curriculum_version before insert on public.enrolments
for each row execute function public.set_enrolment_curriculum_version();

create or replace function public.admin_create_course_version(p_course_id uuid,p_note text default '')
returns integer language plpgsql security definer set search_path=public as $$
declare course_row public.courses%rowtype; next_version integer; curriculum jsonb; note_text text;
begin
 if auth.uid() is null or not public.is_admin() or not public.is_active_user() then
  raise exception 'Active administrator access required';
 end if;
 note_text:=left(trim(coalesce(p_note,'')),500);
 if length(note_text)<3 then raise exception 'Provide a short reason for the curriculum version'; end if;
 select * into course_row from public.courses where id=p_course_id for update;
 if not found then raise exception 'Course not found'; end if;
 if course_row.status<>'published' then raise exception 'Only published courses can receive a new version'; end if;
 next_version:=course_row.current_version+1;

 select jsonb_build_object(
  'version',next_version,
  'change_note',note_text,
  'course',jsonb_set(to_jsonb(c),'{current_version}',to_jsonb(next_version),true),
  'modules',coalesce((
   select jsonb_agg(to_jsonb(m)||jsonb_build_object('lessons',coalesce((
    select jsonb_agg(to_jsonb(l) order by l.position) from public.lessons l where l.module_id=m.id
   ),'[]'::jsonb)) order by m.position)
   from public.modules m where m.course_id=c.id
  ),'[]'::jsonb),
  'assessments',coalesce((
   select jsonb_agg(to_jsonb(a)||jsonb_build_object('questions',coalesce((
    select jsonb_agg(to_jsonb(q)||jsonb_build_object('options',coalesce((
     select jsonb_agg(to_jsonb(o)||jsonb_build_object('is_correct',coalesce(k.is_correct,false),'explanation',coalesce(k.explanation,'')) order by o.position)
     from public.assessment_options o left join public.assessment_answer_keys k on k.option_id=o.id where o.question_id=q.id
    ),'[]'::jsonb)) order by q.position)
    from public.assessment_questions q where q.assessment_id=a.id
   ),'[]'::jsonb)) order by a.created_at)
   from public.assessments a where a.course_id=c.id
  ),'[]'::jsonb)
 ) into curriculum from public.courses c where c.id=p_course_id;

 insert into public.course_versions(course_id,version,snapshot,created_by,approved_by,approved_at)
 values(p_course_id,next_version,curriculum,auth.uid(),auth.uid(),now());
 update public.courses set current_version=next_version,updated_at=now() where id=p_course_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(auth.uid(),'COURSE_VERSION_CREATED','courses',p_course_id,jsonb_build_object('version',next_version,'change_note',note_text));
 return next_version;
end $$;
revoke all on function public.admin_create_course_version(uuid,text) from public,anon;
grant execute on function public.admin_create_course_version(uuid,text) to authenticated;
