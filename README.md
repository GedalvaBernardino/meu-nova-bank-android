# Meu Nova Bank — projetos Android

Fontes dos apps Meu Nova Bank e Meu Nova Bank Admin. Os APKs são builds debug por GitHub Actions.

## Versões atuais
- App do cliente: `MEU-NOVA-BANK-Android-Studio-v0.2.22.zip` (versionCode 33; pendente de build)
- App Admin: `MEU-NOVA-BANK-ADMIN-Android-Studio-v0.2.13.zip` (versionCode 15; pendente de build)

## Limites demonstrativos e Transferência DEM
O Admin configura limite demonstrativo individual para empréstimo pessoal (R$ 102–R$ 90.000) e Meu Nova Card (R$ 152–R$ 90.000); zero desativa. Os limites não constituem oferta, aprovação ou crédito real. O app exibe limite de cartão, utilização e disponibilidade. Transferência DEM pode debitar o saldo demonstrativo do remetente e creditar a conta Meu Nova Bank ativa de destino no ledger de demonstração, atomicamente; há proteção idempotente para repetição da mesma solicitação e lançamentos de débito/crédito.

A opção Meu Nova Card para transferência aplica taxa demonstrativa de 3,7% por operação sobre o valor transferido, adicionada ao valor debitado do limite, que é apresentado antes da confirmação. A chamada autenticada tenta renovar uma sessão expirada e reutiliza o mesmo identificador idempotente em repetição; em caso de resposta ambígua, confira o extrato antes de repetir. A taxa informada para empréstimo é 4,8%, mas sua base/período não foi especificada: nenhum cálculo de parcelas ou custo total é mostrado.

**Tudo é somente demonstrativo:** não alcança Pix, bancos, dinheiro, processadores nem redes de pagamento reais. Não use para movimentação financeira. Nenhuma operação de teste em conta real é realizada.

O backend fonte está em `supabase/migrations/20261023_credit_products_and_dem_transfer.sql` e `supabase/functions/admin-users/index.ts`. A migration deve estar aplicada e a Edge Function implantada no Supabase do projeto. A função `admin-users` mantém `verify_jwt: false`, pois valida bearer token e privilégio Admin manualmente.

## Meu Nova Card demonstrativo
A versão 0.2.22 inclui ativação consentida, bloqueio por perda/furto/roubo e emissão de substituto somente após bloqueio. A face indica permanentemente que não é cartão de pagamento. Os marcadores são deliberadamente inválidos: `0000 0000 0000 0000`, validade ilustrativa `12/99` e código `DEMO` (não é CVV). Nunca use para pagamentos. Transferências DEM pelo cartão são recusadas no servidor se bloqueado, expirado ou sem limite.

Antes de uso, aplique `supabase/migrations/20261023_demo_card_lifecycle.sql`. Não altera saldo, uso histórico, ledger nem ativa cartão existente; cartões existentes iniciam bloqueados/não emitidos. Limite zero bloqueia a demonstração e preserva o valor histórico utilizado. Para testar logicamente em ambiente autorizado, use transação com `ROLLBACK` e confirme inexistência de linhas resultantes; não faça transações em contas de clientes.

## Build APK
Abra Actions → Build Android APKs → Run workflow. Baixe `meu-nova-bank-apk` e `meu-nova-bank-admin-apk`. APKs debug assinados com chave de depuração; artefatos retidos por 30 dias.
