ALTER TABLE public.customer_profiles
  ADD COLUMN IF NOT EXISTS overdraft_admin_limit numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS overdraft_user_limit numeric(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS overdraft_active boolean NOT NULL DEFAULT false;

DO $migration$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.customer_profiles'::regclass AND conname='customer_profiles_overdraft_admin_limit_check') THEN
    ALTER TABLE public.customer_profiles ADD CONSTRAINT customer_profiles_overdraft_admin_limit_check
      CHECK (overdraft_admin_limit = 0 OR overdraft_admin_limit BETWEEN 50 AND 90000);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.customer_profiles'::regclass AND conname='customer_profiles_overdraft_user_limit_check') THEN
    ALTER TABLE public.customer_profiles ADD CONSTRAINT customer_profiles_overdraft_user_limit_check
      CHECK (overdraft_user_limit = 0 OR overdraft_user_limit BETWEEN 50 AND 90000);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.customer_profiles'::regclass AND conname='customer_profiles_overdraft_active_limit_check') THEN
    ALTER TABLE public.customer_profiles ADD CONSTRAINT customer_profiles_overdraft_active_limit_check
      CHECK (NOT overdraft_active OR (overdraft_user_limit >= 50 AND overdraft_user_limit <= overdraft_admin_limit));
  END IF;
END;
$migration$;

ALTER TABLE private.bank_admin_audit
  DROP CONSTRAINT bank_admin_audit_action_check;
ALTER TABLE private.bank_admin_audit
  ADD CONSTRAINT bank_admin_audit_action_check
  CHECK (action = ANY (ARRAY[
    'rename'::text,
    'hide'::text,
    'unhide'::text,
    'close'::text,
    'account_number_edit'::text,
    'interbank_credit'::text,
    'interbank_reject'::text,
    'wallet_balance_edit'::text,
    'feature_visibility_update'::text,
    'profile_update'::text,
    'admin_role_change'::text,
    'theme_change'::text,
    'password_recovery_requested'::text,
    'overdraft_limit_update'::text
  ]));

CREATE OR REPLACE FUNCTION public.meunova_record_admin_action(
  p_actor uuid,
  p_target uuid,
  p_action text,
  p_details jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
BEGIN
  IF p_actor IS NULL
     OR p_action NOT IN (
       'rename', 'hide', 'unhide', 'close', 'account_number_edit',
       'interbank_credit', 'interbank_reject', 'wallet_balance_edit',
       'feature_visibility_update', 'profile_update', 'admin_role_change',
       'theme_change', 'password_recovery_requested', 'overdraft_limit_update'
     )
     OR NOT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_actor) THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  INSERT INTO private.bank_admin_audit(actor_user_id, target_user_id, action, details)
  VALUES (p_actor, p_target, p_action, COALESCE(p_details, '{}'::jsonb));
END;
$function$;

CREATE OR REPLACE FUNCTION public.meunova_admin_set_overdraft_limit(
  p_admin_user_id uuid,
  p_target_user_id uuid,
  p_max_limit numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_status text;
  v_user_limit numeric(12,2);
  v_is_active boolean;
BEGIN
  IF p_admin_user_id IS NULL OR p_target_user_id IS NULL OR p_max_limit IS NULL
     OR (p_max_limit <> 0 AND (p_max_limit < 50 OR p_max_limit > 90000)) THEN
    RAISE EXCEPTION USING MESSAGE = 'invalid overdraft maximum';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_admin_user_id) THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  SELECT p.account_status, p.overdraft_user_limit, p.overdraft_active
    INTO v_status, v_user_limit, v_is_active
    FROM public.customer_profiles p
    WHERE p.user_id = p_target_user_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING MESSAGE = 'target account not found';
  END IF;
  IF p_max_limit > 0 AND v_status <> 'active' THEN
    RAISE EXCEPTION USING MESSAGE = 'target account is not active';
  END IF;
  IF v_is_active AND v_user_limit > p_max_limit THEN
    RAISE EXCEPTION USING MESSAGE = 'active user limit exceeds new maximum; user must deactivate or reduce it first';
  END IF;

  UPDATE public.customer_profiles
    SET overdraft_admin_limit = p_max_limit, updated_at = now()
    WHERE user_id = p_target_user_id;

  PERFORM public.meunova_record_admin_action(
    p_admin_user_id, p_target_user_id, 'overdraft_limit_update',
    jsonb_build_object('max_limit_changed', true, 'max_limit', p_max_limit)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'max_limit', p_max_limit,
    'user_limit', v_user_limit,
    'is_active', v_is_active
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.meunova_set_user_overdraft(
  p_user_limit numeric,
  p_is_active boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid;
  v_admin_limit numeric(12,2);
  v_user_limit numeric(12,2);
  v_active boolean;
  v_account_status text;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL OR p_is_active IS NULL THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  SELECT p.overdraft_admin_limit, p.overdraft_user_limit, p.overdraft_active, p.account_status
    INTO v_admin_limit, v_user_limit, v_active, v_account_status
    FROM public.customer_profiles p
    WHERE p.user_id = v_user_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING MESSAGE = 'profile not found';
  END IF;

  IF p_is_active THEN
    IF v_account_status <> 'active' THEN
      RAISE EXCEPTION USING MESSAGE = 'account is not active';
    END IF;
    IF p_user_limit IS NULL OR p_user_limit < 50 OR p_user_limit > 90000 THEN
      RAISE EXCEPTION USING MESSAGE = 'user limit must be between 50 and 90000';
    END IF;
    IF v_admin_limit < 50 OR p_user_limit > v_admin_limit THEN
      RAISE EXCEPTION USING MESSAGE = 'requested limit exceeds administrator maximum';
    END IF;
    UPDATE public.customer_profiles
      SET overdraft_user_limit = p_user_limit, overdraft_active = true, updated_at = now()
      WHERE user_id = v_user_id;
    v_user_limit := p_user_limit;
    v_active := true;
  ELSE
    UPDATE public.customer_profiles
      SET overdraft_active = false, updated_at = now()
      WHERE user_id = v_user_id;
    v_active := false;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'admin_limit', v_admin_limit,
    'user_limit', v_user_limit,
    'is_active', v_active
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.meunova_admin_set_overdraft_limit(uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.meunova_admin_set_overdraft_limit(uuid, uuid, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.meunova_set_user_overdraft(numeric, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.meunova_set_user_overdraft(numeric, boolean) TO authenticated, service_role;
