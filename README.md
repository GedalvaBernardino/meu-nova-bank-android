# Meu Nova Bank — projetos Android

Este repositório guarda os fontes fornecidos para os projetos **Meu Nova Bank** e **Meu Nova Bank Admin** e compila APKs de depuração pelo GitHub Actions.

## Gerar os APKs

1. Abra a aba **Actions** deste repositório.
2. Selecione **Build Android APKs** e clique em **Run workflow**.
3. Quando a execução terminar, abra-a e baixe os artefatos `meu-nova-bank-apk` e `meu-nova-bank-admin-apk`.
4. Extraia o arquivo do artefato e instale o APK no Android. São builds debug, assinados com chave de depuração.

O build compila os projetos diretamente dos arquivos ZIP originais versionados aqui. Se o Android API 37 ou alguma dependência não estiver disponível no ambiente de build, a execução do Actions indicará o erro.

## Importante

Estes fontes não incluem o backend Supabase/SQL/Edge Functions. Portanto, o APK pode não ter todas as funções operacionais sem configurar o backend. O APK Admin deve ser usado apenas em ambiente de teste autorizado; não o distribua nem o use para alterar dados de terceiros. Este projeto não é uma instituição financeira e não deve ser usado para coletar credenciais bancárias reais.
