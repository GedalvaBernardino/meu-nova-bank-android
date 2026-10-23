Meu Nova Bank Android Studio — 0.2.22

Atualização demonstrativa do ciclo de vida do cartão virtual: ativação consentida, bloqueio por perda/furto/roubo e substituição após bloqueio. O número exibido é 0000 0000 0000 0000, a validade 12/99 é apenas ilustrativa, e o código exibido é DEMO (não é CVV); todos são fictícios e inválidos para pagamento; o protótipo não possui emissor nem processador de pagamentos.

A mudança requer aplicar a migration Supabase `supabase/migrations/20261023_demo_card_lifecycle.sql` antes de usar essas funções. Ativação exige limite configurado de pelo menos R$ 152; bloqueio exige informar perda, furto ou roubo; substituição só é permitida após bloqueio confirmado. O estado é confirmado pelo servidor e as solicitações têm idempotência por UUID. Para compilar: abrir esta pasta no Android Studio e compilar app/debug.
