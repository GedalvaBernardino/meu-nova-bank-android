ALTER TABLE public.customer_profiles
  ADD COLUMN IF NOT EXISTS personal_loan_limit numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS card_credit_limit numeric(12,2) NOT NULL DEFAULT 0;

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
END;
$migration$;

ALTER TABLE private.bank_admin_audit
  DROP CONSTRAINT bank_admin_audit_action_check;
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
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
BEGIN
  IF p_actor IS NULL
     OR p_action NOT IN (
       'rename', 'hide', 'unhide', 'close', 'account_number_edit', 'interbank_credit',
       'interbank_reject', 'wallet_balance_edit', 'feature_visibility_update', 'profile_update',
       'admin_role_change', 'theme_change', 'password_recovery_requested', 'overdraft_limit_update',
       'personal_loan_limit_update', 'card_credit_limit_update'
     )
     OR NOT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_actor) THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  INSERT INTO private.bank_admin_audit(actor_user_id, target_user_id, action, details)
  VALUES (p_actor, p_target, p_action, COALESCE(p_details, '{}'::jsonb));
END;
$function$;

CREATE OR REPLACE FUNCTION public.meunova_admin_set_personal_loan_limit(
  p_admin_user_id uuid, p_target_user_id uuid, p_limit numeric
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
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
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_status text; v_old_limit numeric(12,2);
BEGIN
  IF p_admin_user_id IS NULL OR p_target_user_id IS NULL OR p_limit IS NULL
     OR (p_limit <> 0 AND (p_limit < 152 OR p_limit > 90000)) OR p_limit <> round(p_limit, 2) THEN
    RAISE EXCEPTION USING MESSAGE = 'invalid card credit limit';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_admin_user_id) THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  SELECT p.account_status, p.card_credit_limit INTO v_status, v_old_limit
  FROM public.customer_profiles p WHERE p.user_id = p_target_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE = 'target account not found'; END IF;
  IF p_limit > 0 AND v_status <> 'active' THEN RAISE EXCEPTION USING MESSAGE = 'target account is not active'; END IF;
  UPDATE public.customer_profiles SET card_credit_limit = p_limit, updated_at = now() WHERE user_id = p_target_user_id;
  IF v_old_limit IS DISTINCT FROM p_limit THEN
    PERFORM public.meunova_record_admin_action(p_admin_user_id, p_target_user_id, 'card_credit_limit_update',
      jsonb_build_object('limit_changed', true, 'new_limit', p_limit));
  END IF;
  RETURN jsonb_build_object('ok', true, 'card_credit_limit', p_limit);
END;
$function$;

REVOKE ALL ON FUNCTION public.meunova_admin_set_personal_loan_limit(uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.meunova_admin_set_personal_loan_limit(uuid, uuid, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.meunova_admin_set_card_credit_limit(uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.meunova_admin_set_card_credit_limit(uuid, uuid, numeric) TO service_role;
