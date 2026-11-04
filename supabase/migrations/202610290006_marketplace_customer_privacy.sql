-- Public visitors can discover professionals without reading private service details or prices.
-- Authenticated marketplace accounts retain full reads, subject to the existing RLS policies.
revoke select on public.professionals from anon, public;
revoke select on public.services from anon, public;
grant select(id,display_name,headline,category,location,home_service,business_location,status,profile_state,public_visible,created_at) on public.professionals to anon;
grant select(id,professional_id,title,active) on public.services to anon;
grant select on public.professionals,public.services to authenticated;

-- Authenticated profiles other than customers may see only their own professional/service rows.
drop policy if exists "Eligible published professional profiles are public" on public.professionals;
create policy "Eligible published professional profiles are public" on public.professionals for select using(
 public.is_admin() or profile_id=auth.uid() or
 ((auth.uid() is null or (public.current_role()='customer' and public.is_active_user())) and status='published' and profile_state='published' and public_visible and exists(select 1 from public.profiles pr where pr.id=profile_id and pr.account_status='active'))
);
drop policy if exists "Approved services on published profiles are public" on public.services;
drop policy if exists "Services on published profiles are public" on public.services;
create policy "Approved services on published profiles are public" on public.services for select using(
 public.is_admin() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid() and public.is_active_user()) or
 ((auth.uid() is null or (public.current_role()='customer' and public.is_active_user())) and active and approval_status='published' and exists(select 1 from public.professionals p join public.profiles pr on pr.id=p.profile_id where p.id=professional_id and p.status='published' and p.profile_state='published' and p.public_visible and pr.account_status='active') and
  (not advertised_as_certified or exists(select 1 from public.professional_credentials pc join public.certificates cert on cert.id=pc.certificate_id where pc.professional_id=services.professional_id and pc.category_id=services.category_id and pc.advertised_as_certified and cert.certification_id=services.certification_id and cert.revoked_at is null and (cert.expires_at is null or cert.expires_at>now()))))
);

create or replace function public.marketplace_public_discovery(
 p_search text default '',p_category text default '',p_location text default '',p_service text default '',
 p_min numeric default null,p_max numeric default null,p_home text default '',p_verified boolean default false
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare customer_access boolean; categories_json jsonb; people_json jsonb;
begin
 customer_access:=auth.uid() is not null and public.current_role()='customer' and public.is_active_user();
 if length(coalesce(p_search,''))>80 or length(coalesce(p_category,''))>80 or length(coalesce(p_location,''))>80 or length(coalesce(p_service,''))>80 or coalesce(p_min,0)<0 or coalesce(p_max,0)<0 or coalesce(p_min,0)>100000000 or coalesce(p_max,0)>100000000 or (p_min is not null and p_max is not null and p_min>p_max) or coalesce(p_home,'') not in ('','yes','business') then raise exception 'Invalid marketplace filters'; end if;
 select coalesce(jsonb_agg(to_jsonb(c) order by c.name),'[]'::jsonb) into categories_json from public.marketplace_category_counts() c;
 select coalesce(jsonb_agg(case when customer_access then row_to_json(x)::jsonb else row_to_json(x)::jsonb-ARRAY['rate_from','currency'] end),'[]'::jsonb) into people_json from (
  select p.id,p.display_name,p.headline,p.category,p.location,p.home_service,p.business_location,
   exists(select 1 from public.professional_credentials pc join public.certificates cert on cert.id=pc.certificate_id where pc.professional_id=p.id and pc.advertised_as_certified and cert.revoked_at is null and (cert.expires_at is null or cert.expires_at>now())) as verified,
   (select count(*) from public.services s where s.professional_id=p.id and s.active and s.approval_status='published') as service_count,
   case when customer_access then p.rate_from else null end as rate_from,
   case when customer_access then p.currency else null end as currency
  from public.professionals p join public.profiles pr on pr.id=p.profile_id
  where p.status='published' and p.profile_state='published' and p.public_visible and pr.account_status='active'
   and (coalesce(p_search,'')='' or p.display_name ilike '%'||p_search||'%')
   and (coalesce(p_category,'')='' or p.category=(select mc.name from public.marketplace_categories mc where mc.slug=p_category and mc.active))
   and (coalesce(p_location,'')='' or coalesce(p.location,'') ilike '%'||p_location||'%')
   and (coalesce(p_service,'')='' or exists(select 1 from public.services s where s.professional_id=p.id and s.active and s.approval_status='published' and s.title ilike '%'||p_service||'%'))
   and (customer_access is false or p_min is null or p.rate_from>=p_min)
   and (customer_access is false or p_max is null or p.rate_from<=p_max)
   and (coalesce(p_home,'')<>'yes' or p.home_service)
   and (coalesce(p_home,'')<>'business' or p.business_location)
   and (not coalesce(p_verified,false) or exists(select 1 from public.professional_credentials pc join public.certificates cert on cert.id=pc.certificate_id where pc.professional_id=p.id and pc.advertised_as_certified and cert.revoked_at is null and (cert.expires_at is null or cert.expires_at>now())))
  order by p.created_at desc limit 100
 ) x;
 return jsonb_build_object('categories',categories_json,'professionals',people_json,'customer',customer_access);
end $$;
revoke all on function public.marketplace_public_discovery(text,text,text,text,numeric,numeric,text,boolean) from public;
grant execute on function public.marketplace_public_discovery(text,text,text,text,numeric,numeric,text,boolean) to anon,authenticated;

create or replace function public.marketplace_public_professional_summary(p_professional_id uuid) returns jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object('id',p.id,'display_name',p.display_name,'headline',p.headline,'category',p.category,'location',p.location)
 from public.professionals p join public.profiles pr on pr.id=p.profile_id
 where p.id=p_professional_id and p.status='published' and p.profile_state='published' and p.public_visible and pr.account_status='active'
$$;
revoke all on function public.marketplace_public_professional_summary(uuid) from public;
grant execute on function public.marketplace_public_professional_summary(uuid) to anon,authenticated;

create or replace function public.marketplace_customer_professional_details(p_professional_id uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare pro public.professionals%rowtype;services_json jsonb;credentials_json jsonb;reviews_json jsonb;portfolio_json jsonb;review_count bigint;avg_rating numeric;is_favourite boolean;
begin
 if public.current_role()<>'customer' or not public.is_active_user() then raise exception 'Active customer account required'; end if;
 select p.* into pro from public.professionals p join public.profiles pr on pr.id=p.profile_id where p.id=p_professional_id and p.status='published' and p.profile_state='published' and p.public_visible and pr.account_status='active';
 if pro.id is null then return null; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'title',s.title,'description',s.description,'price',s.price,'duration_minutes',s.duration_minutes,'pricing_unit',s.pricing_unit,'category_id',s.category_id,'advertised_as_certified',s.advertised_as_certified,'certifications',case when cr.id is null then null else jsonb_build_object('title',cr.title) end) order by s.created_at desc),'[]'::jsonb) into services_json
 from public.services s left join lateral(select cert.certification_id from public.professional_credentials pc join public.certificates cert on cert.id=pc.certificate_id where pc.professional_id=s.professional_id and pc.category_id=s.category_id and pc.advertised_as_certified and cert.certification_id=s.certification_id and cert.revoked_at is null and (cert.expires_at is null or cert.expires_at>now()) limit 1) valid on true left join public.certifications cr on cr.id=valid.certification_id where s.professional_id=p_professional_id and s.active and s.approval_status='published';
 select coalesce(jsonb_agg(jsonb_build_object('certificate_id',c.id,'certificates',jsonb_build_object('certificate_number',c.certificate_number,'expires_at',c.expires_at,'certifications',jsonb_build_object('title',cr.title)))),'[]'::jsonb) into credentials_json from public.professional_credentials pc join public.certificates c on c.id=pc.certificate_id join public.certifications cr on cr.id=c.certification_id where pc.professional_id=p_professional_id and c.revoked_at is null and (c.expires_at is null or c.expires_at>now());
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'rating',r.rating,'body',r.body,'created_at',r.created_at) order by r.created_at desc),'[]'::jsonb),count(*),avg(r.rating) into reviews_json,review_count,avg_rating from public.service_reviews r where r.professional_id=p_professional_id and r.status='published';
 select coalesce(jsonb_agg(jsonb_build_object('id',pf.id,'image_path',pf.image_path,'caption',pf.caption,'position',pf.position) order by pf.position),'[]'::jsonb) into portfolio_json from public.professional_portfolio pf where pf.professional_id=p_professional_id;
 select exists(select 1 from public.customer_favourites f where f.customer_id=auth.uid() and f.professional_id=p_professional_id) into is_favourite;
 return jsonb_build_object('professional',jsonb_build_object('id',pro.id,'profile_photo_path',pro.profile_photo_path,'display_name',pro.display_name,'headline',pro.headline,'category',pro.category,'bio',pro.bio,'location',pro.location,'service_area',pro.service_area,'rate_from',pro.rate_from,'currency',pro.currency,'home_service',pro.home_service,'business_location',pro.business_location,'cancellation_policy',pro.cancellation_policy,'booking_preferences',pro.booking_preferences,'availability',pro.availability,'services',services_json,'professional_credentials',credentials_json),'reviews',reviews_json,'review_count',review_count,'average_rating',avg_rating,'favourite',is_favourite,'portfolio',portfolio_json);
end $$;
revoke all on function public.marketplace_customer_professional_details(uuid) from public;
grant execute on function public.marketplace_customer_professional_details(uuid) to authenticated;

create or replace function public.marketplace_public_profile_visible(p_professional_id uuid) returns boolean
language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.professionals p join public.profiles pr on pr.id=p.profile_id where p.id=p_professional_id and p.status='published' and p.profile_state='published' and p.public_visible and pr.account_status='active')
$$;
revoke all on function public.marketplace_public_profile_visible(uuid) from public;
grant execute on function public.marketplace_public_profile_visible(uuid) to anon,authenticated;

drop policy if exists "Eligible published professional profiles are public" on public.professionals;
create policy "Eligible published professional profiles are public" on public.professionals for select using(
 public.is_admin() or profile_id=auth.uid() or
 ((auth.uid() is null or (public.current_role()='customer' and public.is_active_user())) and public.marketplace_public_profile_visible(id))
);
drop policy if exists "Approved services on published profiles are public" on public.services;
create policy "Approved services on published profiles are public" on public.services for select using(
 public.is_admin() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid() and public.is_active_user()) or
 ((auth.uid() is null or (public.current_role()='customer' and public.is_active_user())) and active and approval_status='published' and public.marketplace_public_profile_visible(professional_id) and
  (not advertised_as_certified or exists(select 1 from public.professional_credentials pc join public.certificates cert on cert.id=pc.certificate_id where pc.professional_id=services.professional_id and pc.category_id=services.category_id and pc.advertised_as_certified and cert.certification_id=services.certification_id and cert.revoked_at is null and (cert.expires_at is null or cert.expires_at>now()))))
);
drop policy if exists "Published service reviews are public" on public.service_reviews;
create policy "Published service reviews for marketplace customers" on public.service_reviews for select using(
 public.is_admin() or customer_id=auth.uid() or (status='published' and public.current_role()='customer' and public.is_active_user())
);
drop policy if exists "Public read published professional availability" on public.professional_availability;
create policy "Customers read published professional availability" on public.professional_availability for select to authenticated using(
 public.is_admin() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()) or
 (public.current_role()='customer' and public.is_active_user() and public.marketplace_public_profile_visible(professional_id))
);
drop policy if exists "Owners read published profile media" on storage.objects;
create policy "Customers read published professional profile media" on storage.objects for select to authenticated using(
 bucket_id='profile-media' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin() or
 (public.current_role()='customer' and public.is_active_user() and exists(select 1 from public.professionals p where p.profile_photo_path=name and public.marketplace_public_profile_visible(p.id))))
);
drop policy if exists "Portfolio images visible on public profiles" on storage.objects;
create policy "Customers read published portfolio images" on storage.objects for select to authenticated using(
 bucket_id='professional-portfolios' and (public.is_admin() or (storage.foldername(name))[1]=auth.uid()::text or
 (public.current_role()='customer' and public.is_active_user() and exists(select 1 from public.professional_portfolio pf where pf.image_path=name and pf.consent_confirmed and public.marketplace_public_profile_visible(pf.professional_id))))
);
drop policy if exists "Public verified credentials" on public.professional_credentials;
create policy "Customers read verified professional credentials" on public.professional_credentials for select to authenticated using(
 public.is_admin() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()) or
 (public.current_role()='customer' and public.is_active_user() and public.marketplace_public_profile_visible(professional_id) and exists(select 1 from public.certificates c where c.id=certificate_id and c.revoked_at is null and (c.expires_at is null or c.expires_at>now())))
);
drop policy if exists "Published portfolio is public" on public.professional_portfolio;
create policy "Customers read published portfolio" on public.professional_portfolio for select to authenticated using(
 public.is_admin() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()) or
 (public.current_role()='customer' and public.is_active_user() and consent_confirmed and public.marketplace_public_profile_visible(professional_id))
);
