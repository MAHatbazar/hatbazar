alter table public.products
  add column if not exists description_en text,
  add column if not exists description_bn text,
  add column if not exists attributes jsonb not null default '{}'::jsonb,
  add column if not exists sizes text[] not null default '{}'::text[];