-- Auditoria de pacientes: a mesma função serve pacientes, evoluções e procedimentos realizados.
-- Lê o registro como JSON para não quebrar em tabelas sem a coluna paciente_id
-- (antes dava "record old has no field paciente_id" ao salvar paciente).
create or replace function public.clinica_tg_auditar()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  reg jsonb;
  rid text;
begin
  reg := case when TG_OP = 'DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end;
  rid := coalesce(reg->>'id', '');
  insert into public.clinica_auditoria (usuario_id, papel, acao, tabela, registro_id, detalhe)
  values (auth.uid(), public.clinica_papel_atual(), lower(TG_OP), TG_TABLE_NAME, rid,
          case when TG_TABLE_NAME = 'clinica_evolucoes'
               then 'paciente=' || coalesce(reg->>'paciente_id', '') end);
  if TG_OP = 'DELETE' then return OLD; end if;
  return NEW;
end $function$;
