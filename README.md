# Meu Nova Bank — projetos Android

Este repositório guarda os fontes dos projetos **Meu Nova Bank** e **Meu Nova Bank Admin** e compila APKs de depuração pelo GitHub Actions.

## Gerar os APKs

1. Abra a aba **Actions** deste repositório.
2. Selecione **Build Android APKs** e clique em **Run workflow**.
3. Quando a execução terminar, abra-a e baixe os artefatos `meu-nova-bank-apk` e `meu-nova-bank-admin-apk`.
4. Extraia o arquivo do artefato e instale o APK no Android. São builds debug, assinados com chave de depuração.

O build compila os projetos diretamente dos arquivos ZIP versionados aqui. O arquivo `MEU-NOVA-BANK-Android-Studio-v0.2.15.zip` contém o fluxo Android de recuperação por link enviado ao e-mail confirmado. A Edge Function correspondente está versionada em `supabase/functions/account-password-recovery/index.ts` e é implantada no projeto Supabase do app; o código de backend não é incluído dentro do APK.

## Recuperação de senha

O app aceita números de conta de exatamente 6 dígitos, conforme o banco e o alocador atuais. A pessoa solicita um link usando o número da conta; o servidor busca o e-mail confirmado e envia o link, sem revelar se a conta existe. Só o token de recuperação validado pelo Supabase recebido nesse e-mail autoriza definir a nova senha de 8 dígitos. A entrega do link depende da configuração de e-mail/SMTP e da URL de redirecionamento `meunovabank://auth/callback` no projeto Supabase. Consulte o `PASSWORD-RECOVERY-BACKEND.md` dentro do arquivo ZIP Android.

O APK Admin deve ser usado apenas em ambiente de teste autorizado; não o distribua nem o use para alterar dados de terceiros. Este projeto não é uma instituição financeira e não deve ser usado para coletar credenciais bancárias reais.
