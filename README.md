# Meu Nova Bank — projetos Android

Este repositório guarda os fontes dos projetos **Meu Nova Bank** e **Meu Nova Bank Admin** e compila APKs de depuração pelo GitHub Actions.

## Fontes atuais

- App do cliente: `MEU-NOVA-BANK-Android-Studio-v0.2.17.zip`
- App Admin: `MEU-NOVA-BANK-ADMIN-Android-Studio-v0.2.9.zip`

## Gerar os APKs

1. Abra a aba **Actions** deste repositório.
2. Selecione **Build Android APKs** e clique em **Run workflow**.
3. Quando a execução terminar, abra-a e baixe os artefatos `meu-nova-bank-apk` e `meu-nova-bank-admin-apk`.
4. Extraia o arquivo do artefato e instale o APK no Android. São builds debug, assinados com chave de depuração.

O build compila os projetos diretamente dos arquivos ZIP versionados aqui. Se o Android API 37 ou alguma dependência não estiver disponível no ambiente de build, a execução do Actions indicará o erro.

## Cheque especial demonstrativo

O Admin configura um teto por usuário (R$ 50 a R$ 90.000; zero desativa). O usuário escolhe e ativa um valor entre R$ 50 e o teto que foi definido para sua conta. As mudanças são validadas no servidor e a configuração do Admin é registrada na auditoria.

**É somente uma demonstração de interface:** não concede crédito real, não altera saldos, não cria dívida e não processa pagamentos ou transferências. Os limites ficam desativados por padrão. A migração correspondente está em `supabase/migrations/20261021_overdraft_configuration.sql`, e a ação administrativa está na Edge Function `supabase/functions/admin-users/index.ts`.

## Recuperação de senha

A Edge Function correspondente está versionada em `supabase/functions/account-password-recovery/index.ts` e é implantada no projeto Supabase do app; o código de backend não é incluído dentro do APK.

O app aceita números de conta de exatamente 6 dígitos, conforme o banco e o alocador atuais. A pessoa solicita um link usando o número da conta; o servidor busca o e-mail confirmado e envia o link, sem revelar se a conta existe. Só o token de recuperação validado pelo Supabase recebido nesse e-mail autoriza definir a nova senha de 8 dígitos. A entrega do link depende da configuração de e-mail/SMTP e da URL de redirecionamento `meunovabank://auth/callback` no projeto Supabase. Consulte o arquivo `PASSWORD-RECOVERY-BACKEND.md` dentro do ZIP Android.

## Segurança e escopo

O APK Admin deve ser usado apenas em ambiente de teste autorizado; não o distribua nem o use para alterar dados de terceiros. Este projeto não é uma instituição financeira e não deve ser usado para coletar credenciais bancárias reais.


## Crédito e Transferência DEM demonstrativos

A partir das versões 0.2.17 (app) e 0.2.9 (Admin), os limites por conta para empréstimo pessoal (R$ 102–R$ 90.000) e Meu Nova Card (R$ 152–R$ 90.000) podem ser configurados no Admin; zero desativa. Os limites são configurações demonstrativas, não ofertas ou crédito real. O app consulta apenas os limites do próprio usuário sujeitos a RLS. A taxa informada para transferência no cartão é exibida como 3,7% por operação demonstrativa; nenhuma operação está habilitada. A taxa informada para empréstimo é 4,8%, mas a base/período não foi especificada: nenhum cálculo de parcelas/custo é apresentado.

Transferência DEM permanece em modo de revisão demonstrativa: não debita nem credita saldo. Não existe RPC/servidor de execução implementado nesta versão; habilitar movimento de saldo exigiria uma transação atômica validada no servidor, destinatário interno ativo, saldo suficiente, idempotência e lançamentos de ledger de ambos os lados.

A migration e a Edge Function fonte para limites estão em `supabase/migrations/20261023_credit_products_and_dem_review.sql` e `supabase/functions/admin-users-index.ts`. A migration não foi aplicada nem a Edge Function implantada por este pacote local.
