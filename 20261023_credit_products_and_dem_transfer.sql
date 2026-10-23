ALTER TABLE public.customer_profiles
  ADD COLUMN IF NOT EXISTS personal_loan_limit numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS card_credit_limit numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS card_credit_used numeric(12,2) NOT NULL DEFAULT 0;

DO $migration$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.customer_profiles'::regclass AND conname='customer_profiles_personal_loan_limit_check') THEN
    ALTER TABLE public.customer_profiles ADD CONSTRAINT customer_profiles_personal_loan_limit_check
      CHECK (personal_loan_limit = 0 OR personal_loan_limit BETWEEN 102 AND 90000);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.customer_profiles'::regclass AND conname='customer_profiles_card_credit_limit_check') THEN
    ALTER TABLE public.customer_profiles ADD CONSTRAINT customer_profiles_card_credit_limit_check
      CHECK (card_credit_limit = 0 OR card_credit_limit BETWEEN 152 AND 90000);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.customer_profiles'::regclass AND conname='customer_profiles_card_credit_used_check') THEN
    ALTER TABLE public.customer_profiles ADD CONSTRAINT customer_profiles_card_credit_used_check
      CHECK (card_credit_used >= 0 AND card_credit_used <= card_credit_limit);
  END IF;
END;
$migration$;

ALTER TABLE private.bank_admin_audit DROP CONSTRAINT bank_admin_audit_action_check;
ALTER TABLE private.bank_admin_audit
  ADD CONSTRAINT bank_admin_audit_action_check
  CHECK (action = ANY (ARRAY[
    'rename'::text, 'hide'::text, 'unhide'::text, 'close'::text,
    'account_number_edit'::text, 'interbank_credit'::text, 'interbank_reject'::text,
    'wallet_balance_edit'::text, 'feature_visibility_update'::text, 'profile_update'::text,
    'admin_role_change'::text, 'theme_change'::text, 'password_recovery_requested'::text,
    'overdraft_limit_update'::text, 'personal_loan_limit_update'::text, 'card_credit_limit_update'::text
  ]));

CREATE OR REPLACE FUNCTION public.meunova_record_admin_action(
  p_actor uuid, p_target uuid, p_action text, p_details jsonb DEFAULT '{}'::jsonb
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
BEGIN
  IF p_actor IS NULL OR p_action NOT IN (
    'rename', 'hide', 'unhide', 'close', 'account_number_edit', 'interbank_credit',
    'interbank_reject', 'wallet_balance_edit', 'feature_visibility_update', 'profile_update',
    'admin_role_change', 'theme_change', 'password_recovery_requested', 'overdraft_limit_update',
    'personal_loan_limit_update', 'card_credit_limit_update'
  ) OR NOT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_actor) THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  INSERT INTO private.bank_admin_audit(actor_user_id, target_user_id, action, details)
  VALUES (p_actor, p_target, p_action, COALESCE(p_details, '{}'::jsonb));
END;
$function$;

CREATE OR REPLACE FUNCTION public.meunova_admin_set_personal_loan_limit(
  p_admin_user_id uuid, p_target_user_id uuid, p_limit numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_status text; v_old_limit numeric(12,2);
BEGIN
  IF p_admin_user_id IS NULL OR p_target_user_id IS NULL OR p_limit IS NULL
     OR (p_limit <> 0 AND (p_limit < 102 OR p_limit > 90000)) OR p_limit <> round(p_limit, 2) THEN
    RAISE EXCEPTION USING MESSAGE = 'invalid personal loan limit';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_admin_user_id) THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  SELECT p.account_status, p.personal_loan_limit INTO v_status, v_old_limit
    FROM public.customer_profiles p WHERE p.user_id = p_target_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE = 'target account not found'; END IF;
  IF p_limit > 0 AND v_status <> 'active' THEN RAISE EXCEPTION USING MESSAGE = 'target account is not active'; END IF;
  UPDATE public.customer_profiles SET personal_loan_limit = p_limit, updated_at = now() WHERE user_id = p_target_user_id;
  IF v_old_limit IS DISTINCT FROM p_limit THEN
    PERFORM public.meunova_record_admin_action(p_admin_user_id, p_target_user_id, 'personal_loan_limit_update',
      jsonb_build_object('limit_changed', true, 'new_limit', p_limit));
  END IF;
  RETURN jsonb_build_object('ok', true, 'personal_loan_limit', p_limit);
END;
$function$;

CREATE OR REPLACE FUNCTION public.meunova_admin_set_card_credit_limit(
  p_admin_user_id uuid, p_target_user_id uuid, p_limit numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_status text; v_old_limit numeric(12,2); v_used numeric(12,2);
BEGIN
  IF p_admin_user_id IS NULL OR p_target_user_id IS NULL OR p_limit IS NULL
     OR (p_limit <> 0 AND (p_limit < 152 OR p_limit > 90000)) OR p_limit <> round(p_limit, 2) THEN
    RAISE EXCEPTION USING MESSAGE = 'invalid card credit limit';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_admin_user_id) THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  SELECT p.account_status, p.card_credit_limit, p.card_credit_used INTO v_status, v_old_limit, v_used
    FROM public.customer_profiles p WHERE p.user_id = p_target_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE = 'target account not found'; END IF;
  IF p_limit > 0 AND v_status <> 'active' THEN RAISE EXCEPTION USING MESSAGE = 'target account is not active'; END IF;
  IF p_limit < v_used THEN RAISE EXCEPTION USING MESSAGE = 'new card limit is below current demo usage'; END IF;
  UPDATE public.customer_profiles SET card_credit_limit = p_limit, updated_at = now() WHERE user_id = p_target_user_id;
  IF v_old_limit IS DISTINCT FROM p_limit THEN
    PERFORM public.meunova_record_admin_action(p_admin_user_id, p_target_user_id, 'card_credit_limit_update',
      jsonb_build_object('limit_changed', true, 'new_limit', p_limit));
  END IF;
  RETURN jsonb_build_object('ok', true, 'card_credit_limit', p_limit, 'card_credit_used', v_used);
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

  SELECT * INTO v_existing FROM public.operation_requests r WHERE r.id = p_request_id;
  IF FOUND THEN
    IF v_existing.user_id <> v_user_id OR v_existing.operation_type <> 'dem_transfer'
       OR v_existing.amount <> p_amount OR v_existing.recipient_reference <> p_recipient_account
       OR v_existing.request_data->>'funding_source' <> p_funding_source THEN
      RAISE EXCEPTION USING MESSAGE = 'DEM_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN v_existing.request_data;
  END IF;

  SELECT p.account_number INTO v_sender_account FROM public.customer_profiles p WHERE p.user_id = v_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE = 'active account required'; END IF;
  IF p_recipient_account = v_sender_account THEN RAISE EXCEPTION USING MESSAGE = 'cannot transfer to same account'; END IF;
  SELECT p.user_id INTO v_recipient_id FROM public.customer_profiles p
    WHERE p.account_number = p_recipient_account AND p.account_status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE = 'active DEM recipient not found'; END IF;

  -- Lock both profiles in canonical order so opposite-direction transfers cannot deadlock.
  PERFORM p.user_id FROM public.customer_profiles p
    WHERE p.user_id IN (v_user_id, v_recipient_id) ORDER BY p.user_id FOR UPDATE;

  SELECT p.account_number, p.display_name, p.account_status, p.card_credit_limit, p.card_credit_used
    INTO v_sender_account, v_sender_name, v_sender_status, v_card_limit, v_card_used
    FROM public.customer_profiles p WHERE p.user_id = v_user_id;
  IF NOT FOUND OR v_sender_status <> 'active' THEN RAISE EXCEPTION USING MESSAGE = 'active account required'; END IF;
  IF p_recipient_account = v_sender_account THEN RAISE EXCEPTION USING MESSAGE = 'cannot transfer to same account'; END IF;
  SELECT p.account_number, p.display_name, p.account_status INTO v_sender_account, v_recipient_name, v_recipient_status
    FROM public.customer_profiles p WHERE p.user_id = v_recipient_id;
  IF NOT FOUND OR v_recipient_status <> 'active' OR v_sender_account <> p_recipient_account THEN
    RAISE EXCEPTION USING MESSAGE = 'active DEM recipient not found';
  END IF;
  -- Restore the sender account after reusing the local variable for the recipient number.
  SELECT p.account_number INTO v_sender_account FROM public.customer_profiles p WHERE p.user_id = v_user_id;

  -- A concurrent identical request may have completed while this request waited on the profile locks.
  SELECT * INTO v_existing FROM public.operation_requests r WHERE r.id = p_request_id;
  IF FOUND THEN
    IF v_existing.user_id <> v_user_id OR v_existing.operation_type <> 'dem_transfer'
       OR v_existing.amount <> p_amount OR v_existing.recipient_reference <> p_recipient_account
       OR v_existing.request_data->>'funding_source' <> p_funding_source THEN
      RAISE EXCEPTION USING MESSAGE = 'DEM_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN v_existing.request_data;
  END IF;

  v_charge := p_amount;
  IF p_funding_source = 'card' THEN
    v_fee := round(p_amount * 0.037, 2);
    v_charge := p_amount + v_fee;
    IF v_card_limit < 152 OR v_card_used + v_charge > v_card_limit THEN
      RAISE EXCEPTION USING MESSAGE = 'card limit insufficient for transfer plus fee';
    END IF;
    UPDATE public.customer_profiles SET card_credit_used = card_credit_used + v_charge, updated_at = now()
      WHERE user_id = v_user_id;
  ELSE
    SELECT w.available_balance INTO v_balance FROM public.wallets w WHERE w.user_id = v_user_id FOR UPDATE;
    IF NOT FOUND OR COALESCE(v_balance, 0) < p_amount THEN RAISE EXCEPTION USING MESSAGE = 'insufficient balance'; END IF;
    UPDATE public.wallets SET available_balance = available_balance - p_amount, updated_at = now()
      WHERE user_id = v_user_id;
  END IF;

  UPDATE public.wallets SET available_balance = available_balance + p_amount, updated_at = now()
    WHERE user_id = v_recipient_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE = 'recipient wallet not found'; END IF;

  v_result := jsonb_build_object(
    'ok', true, 'status', 'posted', 'operation_id', p_request_id,
    'sender_account', v_sender_account, 'recipient_account', p_recipient_account,
    'recipient_name', v_recipient_name, 'amount', p_amount, 'funding_source', p_funding_source,
    'fee_rate', CASE WHEN p_funding_source = 'card' THEN 0.037 ELSE 0 END,
    'fee_amount', v_fee, 'charged_amount', v_charge,
    'balances_updated', p_funding_source = 'balance',
    'card_demo_usage_updated', p_funding_source = 'card', 'real_network_used', false
  );
  INSERT INTO public.operation_requests(id, user_id, operation_type, amount, recipient_reference, status, request_data)
    VALUES (p_request_id, v_user_id, 'dem_transfer', p_amount, p_recipient_account, 'approved', v_result);
  INSERT INTO public.ledger_entries(user_id, operation_id, entry_type, amount, description, entry_status)
    VALUES (v_user_id, p_request_id, 'debit', v_charge,
      CASE WHEN p_funding_source = 'card'
        THEN 'Transferência DEM Meu Nova Card · valor + taxa de 3,7%'
        ELSE 'Transferência DEM enviada para conta ' || p_recipient_account END, 'posted');
  INSERT INTO public.ledger_entries(user_id, operation_id, entry_type, amount, description, entry_status)
    VALUES (v_recipient_id, p_request_id, 'credit', p_amount,
      'Transferência DEM recebida de conta ' || v_sender_account, 'posted');
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.meunova_admin_set_personal_loan_limit(uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.meunova_admin_set_personal_loan_limit(uuid, uuid, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.meunova_admin_set_card_credit_limit(uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.meunova_admin_set_card_credit_limit(uuid, uuid, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.meunova_execute_dem_transfer(uuid, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.meunova_execute_dem_transfer(uuid, text, numeric, text) TO authenticated, service_role;
