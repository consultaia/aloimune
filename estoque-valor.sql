-- Estoque: valor e fornecedor de cada produto (insumos). Pode rodar de novo sem problema.
alter table public.insumos add column if not exists valor_unitario    numeric;  -- R$ por unidade
alter table public.insumos add column if not exists fornecedor        text;
alter table public.insumos add column if not exists fornecedor_contato text;    -- telefone, e-mail ou site
