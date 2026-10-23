ALTER TABLE public.customer_profiles
  ADD COLUMN IF NOT EXISTS demo_card_active boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS demo_card_generation integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS demo_card_expires_on date,
  ADD COLUMN IF NOT EXISTS demo_card_block_reason text;

ALTER TABLE public.customer_profiles DROP CONSTRAINT IF EXISTS customer_profiles_card_credit_used_check;
ALTER TABLE public.customer_profiles ADD CONSTRAINT customer_profiles_card_credit_used_check
  CHECK (card_credit_used >= 0 AND (card_credit_limit = 0 OR card_credit_used <= card_credit_limit));

DO $migration$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.customer_profiles'::regclass AND conname='customer_profiles_demo_card_generation_check') THEN
    ALTER TABLE public.customer_profiles ADD CONSTRAINT customer_profiles_demo_card_generation_check CHECK (demo_card_generation >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.customer_profiles'::regclass AND conname='customer_profiles_demo_card_active_check') THEN
    ALTER TABLE public.customer_profiles ADD CONSTRAINT customer_profiles_demo_card_active_check
      CHECK (NOT demo_card_active OR (card_credit_limit >= 152 AND demo_card_generation >= 1 AND demo_card_expires_on IS NOT NULL));
  END IF;
END;
$migration$;

CREATE TABLE IF NOT EXISTS private.demo_card_requests (
  user_id uuid NOT NULL,
  request_id uuid NOT NULL,
  action text NOT NULL CHECK (action IN ('issue','block','replace')),
  block_reason text CHECK (block_reason IS NULL OR block_reason IN ('perda','furto','roubo')),
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, request_id),
  CHECK ((action = 'block') = (block_reason IS NOT NULL))
);
REVOKE ALL ON TABLE private.demo_card_requests FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.meunova_admin_set_card_credit_limit(
  p_admin_user_id uuid, p_target_user_id uuid, p_limit numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_status text;
  v_old_limit numeric(12,2);
  v_used numeric(12,2);
  v_active boolean;
  v_generation integer;
BEGIN
  IF p_admin_user_id IS NULL OR p_target_user_id IS NULL OR p_limit IS NULL
     OR (p_limit <> 0 AND (p_limit < 152 OR p_limit > 90000)) OR p_limit <> round(p_limit, 2) THEN
    RAISE EXCEPTION USING MESSAGE = 'invalid card credit limit';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_admin_user_id) THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  SELECT p.account_status, p.card_credit_limit, p.card_credit_used,
         p.demo_card_active, p.demo_card_generation
    INTO v_status, v_old_limit, v_used, v_active, v_generation
    FROM public.customer_profiles p WHERE p.user_id = p_target_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE = 'target account not found'; END IF;
  IF p_limit > 0 AND v_status <> 'active' THEN RAISE EXCEPTION USING MESSAGE = 'target account is not active'; END IF;
  UPDATE public.customer_profiles
     SET card_credit_limit = p_limit,
         demo_card_active = CASE WHEN p_limit = 0 THEN false ELSE demo_card_active END,
         demo_card_block_reason = CASE WHEN p_limit = 0 THEN NULL ELSE demo_card_block_reason END,
         updated_at = now()
   WHERE user_id = p_target_user_id;
  IF v_old_limit IS DISTINCT FROM p_limit THEN
    PERFORM public.meunova_record_admin_action(p_admin_user_id, p_target_user_id, 'card_credit_limit_update',
      jsonb_build_object('limit_changed', true, 'new_limit', p_limit));
  END IF;
  RETURN jsonb_build_object('ok', true, 'card_credit_limit', p_limit, 'card_credit_used', v_used,
    'demo_card_active', CASE WHEN p_limit = 0 THEN false ELSE v_active END,
    'demo_card_generation', v_generation);
END;
$function$;

DROP FUNCTION IF EXISTS public.meunova_set_demo_card_state(text, text);
CREATE OR REPLACE FUNCTION public.meunova_set_demo_card_state(p_action text, p_block_reason text, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid(); v_status text; v_limit numeric(12,2); v_active boolean;
  v_generation integer; v_expiry date; v_result jsonb; v_existing private.demo_card_requests%rowtype;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION USING MESSAGE='authentication required'; END IF;
  IF p_action IS NULL OR p_action NOT IN ('issue','block','replace') OR p_request_id IS NULL THEN
    RAISE EXCEPTION USING MESSAGE='invalid demo card action';
  END IF;
  IF p_action <> 'block' AND p_block_reason IS NOT NULL THEN RAISE EXCEPTION USING MESSAGE='block reason only applies to blocking'; END IF;
  IF p_action = 'block' AND (p_block_reason IS NULL OR p_block_reason NOT IN ('perda','furto','roubo')) THEN
    RAISE EXCEPTION USING MESSAGE='select a valid blocking reason';
  END IF;
  SELECT p.account_status,p.card_credit_limit,p.demo_card_active,p.demo_card_generation,p.demo_card_expires_on
    INTO v_status,v_limit,v_active,v_generation,v_expiry
    FROM public.customer_profiles p WHERE p.user_id=v_user_id FOR UPDATE;
  IF NOT FOUND OR v_status <> 'active' THEN RAISE EXCEPTION USING MESSAGE='active account required'; END IF;
  SELECT * INTO v_existing FROM private.demo_card_requests r WHERE r.user_id=v_user_id AND r.request_id=p_request_id;
  IF FOUND THEN
    IF v_existing.action IS DISTINCT FROM p_action OR v_existing.block_reason IS DISTINCT FROM p_block_reason THEN
      RAISE EXCEPTION USING MESSAGE='DEMO_CARD_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN v_existing.response;
  END IF;
  IF p_action='block' THEN
    IF NOT v_active THEN RAISE EXCEPTION USING MESSAGE='demo card is already blocked'; END IF;
    UPDATE public.customer_profiles SET demo_card_active=false,demo_card_block_reason=p_block_reason,updated_at=now() WHERE user_id=v_user_id;
    v_active:=false;
  ELSIF p_action='issue' THEN
    IF v_active OR v_generation<>0 THEN RAISE EXCEPTION USING MESSAGE='demo card has already been issued'; END IF;
    IF v_limit<152 THEN RAISE EXCEPTION USING MESSAGE='card limit is not configured'; END IF;
    v_generation:=1; v_active:=true; v_expiry:=(CURRENT_DATE+INTERVAL '3 years')::date;
    UPDATE public.customer_profiles SET demo_card_active=true,demo_card_generation=v_generation,demo_card_expires_on=v_expiry,
      demo_card_block_reason=NULL,updated_at=now() WHERE user_id=v_user_id;
  ELSE
    IF v_active THEN RAISE EXCEPTION USING MESSAGE='block the current demo card before replacing it'; END IF;
    IF v_generation<1 OR v_limit<152 THEN RAISE EXCEPTION USING MESSAGE='card limit is not configured'; END IF;
    v_generation:=v_generation+1; v_active:=true; v_expiry:=(CURRENT_DATE+INTERVAL '3 years')::date;
    UPDATE public.customer_profiles SET demo_card_active=true,demo_card_generation=v_generation,demo_card_expires_on=v_expiry,
      demo_card_block_reason=NULL,updated_at=now() WHERE user_id=v_user_id;
  END IF;
  v_result:=jsonb_build_object('ok',true,'demo_card_active',v_active,'demo_card_generation',v_generation,
    'demo_card_expires_on',v_expiry,'real_payment_card',false);
  INSERT INTO private.demo_card_requests(user_id,request_id,action,block_reason,response)
    VALUES(v_user_id,p_request_id,p_action,p_block_reason,v_result);
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.meunova_execute_dem_transfer(
  p_request_id uuid, p_recipient_account text, p_amount numeric, p_funding_source text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_sender_account text;
  v_sender_name text;
  v_sender_status text;
  v_card_limit numeric(12,2);
  v_card_used numeric(12,2);
  v_demo_card_active boolean;
  v_demo_card_expires_on date;
  v_balance numeric(14,2);
  v_recipient_id uuid;
  v_recipient_name text;
  v_recipient_status text;
  v_fee numeric(12,2) := 0;
  v_charge numeric(12,2);
  v_existing public.operation_requests%rowtype;
  v_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION USING MESSAGE = 'authentication required'; END IF;
  IF p_request_id IS NULL OR p_recipient_account IS NULL OR p_recipient_account !~ '^[0-9]{6}$'
     OR p_amount IS NULL OR p_amount <= 0 OR p_amount > 90000 OR p_amount <> round(p_amount, 2)
     OR p_funding_source IS NULL OR p_funding_source NOT IN ('balance', 'card') THEN
    RAISE EXCEPTION USING MESSAGE = 'invalid transfer data';
  END IF;
  SELECT * INTO v_existing FROM public.operation_requests r WHERE r.id=p_request_id;
  IF FOUND THEN
    IF v_existing.user_id<>v_user_id OR v_existing.operation_type<>'dem_transfer'
       OR v_existing.amount<>p_amount OR v_existing.recipient_reference<>p_recipient_account
       OR v_existing.request_data->>'funding_source'<>p_funding_source THEN
      RAISE EXCEPTION USING MESSAGE='DEM_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN v_existing.request_data;
  END IF;
  SELECT p.account_number INTO v_sender_account FROM public.customer_profiles p WHERE p.user_id=v_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE='active account required'; END IF;
  IF p_recipient_account=v_sender_account THEN RAISE EXCEPTION USING MESSAGE='cannot transfer to same account'; END IF;
  SELECT p.user_id INTO v_recipient_id FROM public.customer_profiles p
    WHERE p.account_number=p_recipient_account AND p.account_status='active';
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE='active DEM recipient not found'; END IF;
  PERFORM p.user_id FROM public.customer_profiles p
    WHERE p.user_id IN (v_user_id,v_recipient_id) ORDER BY p.user_id FOR UPDATE;
  SELECT p.account_number,p.display_name,p.account_status,p.card_credit_limit,p.card_credit_used,p.demo_card_active,p.demo_card_expires_on
    INTO v_sender_account,v_sender_name,v_sender_status,v_card_limit,v_card_used,v_demo_card_active,v_demo_card_expires_on
    FROM public.customer_profiles p WHERE p.user_id=v_user_id;
  IF NOT FOUND OR v_sender_status<>'active' THEN RAISE EXCEPTION USING MESSAGE='active account required'; END IF;
  IF p_recipient_account=v_sender_account THEN RAISE EXCEPTION USING MESSAGE='cannot transfer to same account'; END IF;
  SELECT p.account_number,p.display_name,p.account_status INTO v_sender_account,v_recipient_name,v_recipient_status
    FROM public.customer_profiles p WHERE p.user_id=v_recipient_id;
  IF NOT FOUND OR v_recipient_status<>'active' OR v_sender_account<>p_recipient_account THEN
    RAISE EXCEPTION USING MESSAGE='active DEM recipient not found';
  END IF;
  SELECT p.account_number INTO v_sender_account FROM public.customer_profiles p WHERE p.user_id=v_user_id;
  SELECT * INTO v_existing FROM public.operation_requests r WHERE r.id=p_request_id;
  IF FOUND THEN
    IF v_existing.user_id<>v_user_id OR v_existing.operation_type<>'dem_transfer'
       OR v_existing.amount<>p_amount OR v_existing.recipient_reference<>p_recipient_account
       OR v_existing.request_data->>'funding_source'<>p_funding_source THEN
      RAISE EXCEPTION USING MESSAGE='DEM_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN v_existing.request_data;
  END IF;
  v_charge:=p_amount;
  IF p_funding_source='card' THEN
    IF NOT v_demo_card_active OR v_demo_card_expires_on IS NULL OR v_demo_card_expires_on < CURRENT_DATE THEN RAISE EXCEPTION USING MESSAGE='demo card is blocked or expired'; END IF;
    v_fee:=round(p_amount*0.037,2); v_charge:=p_amount+v_fee;
    IF v_card_limit<152 OR v_card_used+v_charge>v_card_limit THEN
      RAISE EXCEPTION USING MESSAGE='card limit insufficient for transfer plus fee';
    END IF;
    UPDATE public.customer_profiles SET card_credit_used=card_credit_used+v_charge,updated_at=now() WHERE user_id=v_user_id;
  ELSE
    SELECT w.available_balance INTO v_balance FROM public.wallets w WHERE w.user_id=v_user_id FOR UPDATE;
    IF NOT FOUND OR COALESCE(v_balance,0)<p_amount THEN RAISE EXCEPTION USING MESSAGE='insufficient balance'; END IF;
    UPDATE public.wallets SET available_balance=available_balance-p_amount,updated_at=now() WHERE user_id=v_user_id;
  END IF;
  UPDATE public.wallets SET available_balance=available_balance+p_amount,updated_at=now() WHERE user_id=v_recipient_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE='recipient wallet not found'; END IF;
  v_result:=jsonb_build_object('ok',true,'status','posted','operation_id',p_request_id,
    'sender_account',v_sender_account,'recipient_account',p_recipient_account,'recipient_name',v_recipient_name,
    'amount',p_amount,'funding_source',p_funding_source,
    'fee_rate',CASE WHEN p_funding_source='card' THEN 0.037 ELSE 0 END,
    'fee_amount',v_fee,'charged_amount',v_charge,'balances_updated',p_funding_source='balance',
    'card_demo_usage_updated',p_funding_source='card','real_network_used',false);
  INSERT INTO public.operation_requests(id,user_id,operation_type,amount,recipient_reference,status,request_data)
    VALUES(p_request_id,v_user_id,'dem_transfer',p_amount,p_recipient_account,'approved',v_result);
  INSERT INTO public.ledger_entries(user_id,operation_id,entry_type,amount,description,entry_status)
    VALUES(v_user_id,p_request_id,'debit',v_charge,
      CASE WHEN p_funding_source='card' THEN 'Transferência DEM Meu Nova Card · valor + taxa de 3,7%'
        ELSE 'Transferência DEM enviada para conta '||p_recipient_account END,'posted');
  INSERT INTO public.ledger_entries(user_id,operation_id,entry_type,amount,description,entry_status)
    VALUES(v_recipient_id,p_request_id,'credit',p_amount,'Transferência DEM recebida de conta '||v_sender_account,'posted');
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.meunova_set_demo_card_state(text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.meunova_set_demo_card_state(text, text, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.meunova_admin_set_card_credit_limit(uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.meunova_admin_set_card_credit_limit(uuid, uuid, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.meunova_execute_dem_transfer(uuid, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.meunova_execute_dem_transfer(uuid, text, numeric, text) TO authenticated, service_role;
