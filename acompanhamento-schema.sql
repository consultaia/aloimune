-- ============================================================================
-- ACOMPANHAMENTO PÓS-CONSULTA (substitui o Google Forms "ALOIMUNE |
-- ACOMPANHAMENTO PÓS-CONSULTA").
-- Rode no Supabase (SQL Editor), no mesmo projeto dos outros módulos.
-- Pode rodar de novo sem problema (idempotente).
--
-- Quem faz o quê (garantido pelo banco, RLS):
--   • gestor ................ vê, cria, edita e arquiva todos
--   • auditoria ............. vê todos (só leitura)
--   • recepcionista / medico  vê, cria e edita todos
--   • funcionario ........... cria e vê/edita só os que ele mesmo registrou
--   • toda alteração fica em clinica_acompanhamentos_historico (quem, quando, o quê)
--   • a lista de nomes da caixa "Responsável pelo contato" fica em
--     clinica_acompanhamento_responsaveis (a equipe coloca e tira nomes)
--
-- Atualização (out/2026): "próximo passo" passou a aceitar vários. Quem já tinha
-- rodado a versão anterior só precisa rodar este arquivo de novo — os dados de
-- proximo_passo são copiados para proximos_passos automaticamente.
--
-- Integração com o Google Forms: veja o fim deste arquivo e
-- google-forms-acompanhamento.gs (script para colar no formulário).
-- ============================================================================

create table if not exists public.clinica_acompanhamentos (
  id                   uuid primary key default gen_random_uuid(),
  criado_em            timestamptz not null default now(),
  criado_por           uuid default auth.uid(),
  criado_por_nome      text,
  atualizado_em        timestamptz not null default now(),
  atualizado_por       uuid,
  paciente_id          uuid,                 -- liga a clinica_pacientes quando a paciente já está cadastrada
  paciente             text not null,
  telefone             text,
  data_consulta        date,
  proximos_passos      text[] not null default '{}',   -- vários: {etapa1, usg, ...}
  proximo_passo_outro  text,
  prazo                date,                 -- prazo para acompanhamento
  responsavel          text,                 -- responsável pelo contato
  situacao             text not null default 'pendente'
                       check (situacao in ('pendente','em_andamento','concluido')),
  concluido_em         timestamptz,
  observacoes          text,
  ativo                boolean not null default true
);

-- migração da versão com um único próximo passo
alter table public.clinica_acompanhamentos add column if not exists proximos_passos text[] not null default '{}';
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'clinica_acompanhamentos' and column_name = 'proximo_passo') then
    drop trigger if exists acomp_carimbo on public.clinica_acompanhamentos;   -- recriado abaixo; evita poluir o histórico
    update public.clinica_acompanhamentos
       set proximos_passos = array[proximo_passo]
     where proximo_passo is not null and cardinality(proximos_passos) = 0;
    alter table public.clinica_acompanhamentos drop column proximo_passo;
  end if;
end $$;

alter table public.clinica_acompanhamentos drop constraint if exists clinica_acomp_passos_check;
alter table public.clinica_acompanhamentos add constraint clinica_acomp_passos_check
  check (proximos_passos <@ array['etapa1','etapa2','etapa3','consulta','retorno','usg',
                                  'reforco_crossmatch','reforco_intralipid','vacina','exames_pre','outro']::text[]);

create index if not exists clinica_acomp_situacao_idx on public.clinica_acompanhamentos (situacao, prazo) where ativo;
create index if not exists clinica_acomp_paciente_idx on public.clinica_acompanhamentos (paciente_id);
create index if not exists clinica_acomp_criado_idx   on public.clinica_acompanhamentos (criado_por);

create table if not exists public.clinica_acompanhamentos_historico (
  id               bigserial primary key,
  acompanhamento_id uuid not null references public.clinica_acompanhamentos(id) on delete cascade,
  quando           timestamptz not null default now(),
  quem             uuid default auth.uid(),
  quem_nome        text,
  acao             text not null,     -- 'criou' | 'editou'
  campos           jsonb              -- { "situacao": ["pendente","concluido"], ... }  (antes, depois)
);
create index if not exists clinica_acomp_hist_idx on public.clinica_acompanhamentos_historico (acompanhamento_id, quando desc);

-- nomes que aparecem na caixa "Responsável pelo contato"
create table if not exists public.clinica_acompanhamento_responsaveis (
  nome      text primary key,
  criado_em timestamptz not null default now()
);
insert into public.clinica_acompanhamento_responsaveis (nome)
  select distinct trim(responsavel) from public.clinica_acompanhamentos
  where coalesce(trim(responsavel), '') <> ''
on conflict do nothing;

-- papel e nome de quem está logado (lidos de perfis sem esbarrar no RLS de perfis)
create or replace function public.acomp_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where id = auth.uid()
$$;

create or replace function public.acomp_nome() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(p.nome,''), u.email)
  from auth.users u left join public.perfis p on p.id = u.id
  where u.id = auth.uid()
$$;

-- carimbos de autoria, data de conclusão e histórico
create or replace function public.acomp_carimbo() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  dif jsonb := '{}';
  k text;
begin
  if tg_op = 'INSERT' then
    new.criado_por      := coalesce(auth.uid(), new.criado_por);
    new.criado_por_nome := coalesce(public.acomp_nome(), new.criado_por_nome);
    new.atualizado_em   := now();
    new.atualizado_por  := auth.uid();
    new.concluido_em    := case when new.situacao = 'concluido' then now() end;
    return new;
  end if;
  -- UPDATE: autoria original não pode ser trocada
  new.criado_por      := old.criado_por;
  new.criado_por_nome := old.criado_por_nome;
  new.criado_em       := old.criado_em;
  new.atualizado_em   := now();
  new.atualizado_por  := auth.uid();
  if new.situacao = 'concluido' and old.situacao <> 'concluido' then new.concluido_em := now();
  elsif new.situacao <> 'concluido' then new.concluido_em := null;
  else new.concluido_em := old.concluido_em; end if;
  for k in select jsonb_object_keys(to_jsonb(new)) loop
    if k not in ('atualizado_em','atualizado_por','concluido_em')
       and (to_jsonb(new) -> k) is distinct from (to_jsonb(old) -> k) then
      dif := dif || jsonb_build_object(k, jsonb_build_array(to_jsonb(old) -> k, to_jsonb(new) -> k));
    end if;
  end loop;
  if dif <> '{}' then
    insert into public.clinica_acompanhamentos_historico (acompanhamento_id, quem, quem_nome, acao, campos)
    values (new.id, auth.uid(), public.acomp_nome(), 'editou', dif);
  end if;
  return new;
end $$;

create or replace function public.acomp_criado() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.clinica_acompanhamentos_historico (acompanhamento_id, quem, quem_nome, acao)
  values (new.id, coalesce(auth.uid(), new.criado_por), coalesce(public.acomp_nome(), new.criado_por_nome), 'criou');
  return new;
end $$;

drop trigger if exists acomp_carimbo on public.clinica_acompanhamentos;
create trigger acomp_carimbo before insert or update on public.clinica_acompanhamentos
  for each row execute function public.acomp_carimbo();

drop trigger if exists acomp_criado on public.clinica_acompanhamentos;
create trigger acomp_criado after insert on public.clinica_acompanhamentos
  for each row execute function public.acomp_criado();

-- ---------------------------------------------------------------- RLS
alter table public.clinica_acompanhamentos           enable row level security;
alter table public.clinica_acompanhamentos_historico enable row level security;
alter table public.clinica_acompanhamento_responsaveis enable row level security;

drop policy if exists acomp_ler      on public.clinica_acompanhamentos;
drop policy if exists acomp_criar    on public.clinica_acompanhamentos;
drop policy if exists acomp_editar   on public.clinica_acompanhamentos;
drop policy if exists acomp_apagar   on public.clinica_acompanhamentos;
drop policy if exists acomp_hist_ler on public.clinica_acompanhamentos_historico;
drop policy if exists acomp_resp_ler    on public.clinica_acompanhamento_responsaveis;
drop policy if exists acomp_resp_criar  on public.clinica_acompanhamento_responsaveis;
drop policy if exists acomp_resp_apagar on public.clinica_acompanhamento_responsaveis;

create policy acomp_ler on public.clinica_acompanhamentos for select to authenticated
  using ( public.acomp_papel() in ('gestor','auditoria','recepcionista','medico')
          or (public.acomp_papel() = 'funcionario' and criado_por = auth.uid()) );

create policy acomp_criar on public.clinica_acompanhamentos for insert to authenticated
  with check ( public.acomp_papel() in ('gestor','recepcionista','medico','funcionario') );

create policy acomp_editar on public.clinica_acompanhamentos for update to authenticated
  using ( public.acomp_papel() in ('gestor','recepcionista','medico')
          or (public.acomp_papel() = 'funcionario' and criado_por = auth.uid()) )
  with check ( public.acomp_papel() in ('gestor','recepcionista','medico')
          or (public.acomp_papel() = 'funcionario' and criado_por = auth.uid()) );

create policy acomp_apagar on public.clinica_acompanhamentos for delete to authenticated
  using ( public.acomp_papel() = 'gestor' );

create policy acomp_hist_ler on public.clinica_acompanhamentos_historico for select to authenticated
  using ( exists (select 1 from public.clinica_acompanhamentos a
                  where a.id = clinica_acompanhamentos_historico.acompanhamento_id) );  -- herda o RLS do acompanhamento

create policy acomp_resp_ler on public.clinica_acompanhamento_responsaveis for select to authenticated
  using ( public.acomp_papel() in ('gestor','auditoria','recepcionista','medico','funcionario') );
create policy acomp_resp_criar on public.clinica_acompanhamento_responsaveis for insert to authenticated
  with check ( public.acomp_papel() in ('gestor','recepcionista','medico','funcionario') );
create policy acomp_resp_apagar on public.clinica_acompanhamento_responsaveis for delete to authenticated
  using ( public.acomp_papel() in ('gestor','recepcionista','medico','funcionario') );

grant select, insert, update, delete on public.clinica_acompanhamentos to authenticated;
grant select, insert, delete on public.clinica_acompanhamento_responsaveis to authenticated;
grant select on public.clinica_acompanhamentos_historico to authenticated;

-- ============================================================================
-- INTEGRAÇÃO COM O GOOGLE FORMS
-- Cada resposta enviada no Forms vira um acompanhamento aqui (situação vinda do
-- formulário, ou "Pendente"). O script do Forms chama acomp_receber_forms() com
-- uma senha secreta; sem a senha certa nada é gravado.
-- Para ver a senha (cole no script do Forms):
--   select valor from public.clinica_integracoes where chave = 'acomp_forms_segredo';
-- Para trocar a senha:
--   update public.clinica_integracoes set valor = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
--   where chave = 'acomp_forms_segredo';
-- ============================================================================

alter table public.clinica_acompanhamentos add column if not exists forms_resposta_id text;  -- evita duplicar a mesma resposta
create unique index if not exists clinica_acomp_forms_idx on public.clinica_acompanhamentos (forms_resposta_id);

-- guarda segredos de integração; RLS ligado e sem nenhuma policy = ninguém lê pela API
create table if not exists public.clinica_integracoes (
  chave     text primary key,
  valor     text not null,
  criado_em timestamptz not null default now()
);
alter table public.clinica_integracoes enable row level security;
revoke all on public.clinica_integracoes from anon, authenticated;
insert into public.clinica_integracoes (chave, valor)
  values ('acomp_forms_segredo', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
on conflict (chave) do nothing;

create or replace function public.acomp_receber_forms(segredo text, dados jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_pid    uuid;
  v_uid    uuid;
  v_nome   text;
  v_email  text := lower(nullif(trim(dados->>'email'), ''));
  v_pac    text := nullif(trim(regexp_replace(coalesce(dados->>'paciente', ''), '\s+', ' ', 'g')), '');
  v_resp   text := nullif(trim(regexp_replace(coalesce(dados->>'responsavel', ''), '\s+', ' ', 'g')), '');
  v_sit    text := coalesce(nullif(dados->>'situacao', ''), 'pendente');
  v_passos text[];
  v_rid    text := nullif(dados->>'resposta_id', '');
begin
  if segredo is null or not exists (select 1 from public.clinica_integracoes
                                    where chave = 'acomp_forms_segredo' and valor = segredo) then
    raise exception 'senha da integração inválida' using errcode = '28000';
  end if;
  if v_pac is null then raise exception 'resposta sem o nome da paciente'; end if;

  -- a mesma resposta reenviada não duplica
  if v_rid is not null then
    select id into v_id from public.clinica_acompanhamentos where forms_resposta_id = v_rid;
    if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'repetida', true); end if;
  end if;

  select coalesce(array_agg(distinct p), '{}') into v_passos
    from jsonb_array_elements_text(case when jsonb_typeof(dados->'passos') = 'array' then dados->'passos' else '[]'::jsonb end) p
   where p = any (array['etapa1','etapa2','etapa3','consulta','retorno','usg',
                        'reforco_crossmatch','reforco_intralipid','vacina','exames_pre','outro']);
  if v_sit not in ('pendente','em_andamento','concluido') then v_sit := 'pendente'; end if;

  -- quem respondeu (se o Forms coleta e-mail e a pessoa tem login na plataforma)
  if v_email is not null then
    select u.id, coalesce(nullif(pf.nome, ''), u.email) into v_uid, v_nome
      from auth.users u left join public.perfis pf on pf.id = u.id
     where lower(u.email) = v_email limit 1;
  end if;
  -- liga ao cadastro de pacientes pelo nome, se o módulo Pacientes existir
  if to_regclass('public.clinica_pacientes') is not null then
    execute 'select id from public.clinica_pacientes where lower(trim(nome)) = lower($1) limit 1' into v_pid using v_pac;
  end if;

  insert into public.clinica_acompanhamentos
    (paciente, paciente_id, telefone, data_consulta, proximos_passos, proximo_passo_outro, prazo, responsavel,
     situacao, observacoes, criado_por, criado_por_nome, criado_em, forms_resposta_id)
  values
    (v_pac, v_pid, nullif(trim(dados->>'telefone'), ''),
     case when dados->>'data_consulta' ~ '^\d{4}-\d{2}-\d{2}$' then (dados->>'data_consulta')::date end,
     v_passos,
     case when 'outro' = any (v_passos) then nullif(trim(dados->>'outro'), '') end,
     case when dados->>'prazo' ~ '^\d{4}-\d{2}-\d{2}$' then (dados->>'prazo')::date end,
     v_resp, v_sit, nullif(trim(dados->>'observacoes'), ''),
     v_uid, coalesce(v_nome, v_email, 'Equipe') || ' · via Forms',
     coalesce(case when dados->>'enviado_em' ~ '^\d{4}-\d{2}-\d{2}T' then (dados->>'enviado_em')::timestamptz end, now()),
     v_rid)
  returning id into v_id;

  if v_resp is not null then
    insert into public.clinica_acompanhamento_responsaveis (nome) values (v_resp) on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

revoke all on function public.acomp_receber_forms(text, jsonb) from public;
grant execute on function public.acomp_receber_forms(text, jsonb) to anon, authenticated;
