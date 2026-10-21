ALTER TABLE public.customer_profiles
  ADD COLUMN IF NOT EXISTS theme_tier text NOT NULL DEFAULT 'basic';

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.customer_profiles'::regclass
      AND conname = 'customer_profiles_theme_tier_check'
  ) THEN
    ALTER TABLE public.customer_profiles
      ADD CONSTRAINT customer_profiles_theme_tier_check
      CHECK (theme_tier = ANY (ARRAY['basic'::text, 'select'::text, 'platinum'::text, 'gold'::text, 'black'::text]));
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
    'password_recovery_requested'::text
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
       'theme_change', 'password_recovery_requested'
     )
     OR NOT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_actor) THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  INSERT INTO private.bank_admin_audit(actor_user_id, target_user_id, action, details)
  VALUES (p_actor, p_target, p_action, COALESCE(p_details, '{}'::jsonb));
END;
$function$;

CREATE OR REPLACE FUNCTION public.meunova_set_bank_admin_role(
  p_actor uuid,
  p_target uuid,
  p_is_admin boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_is_admin boolean;
  v_admin_count integer;
BEGIN
  IF p_actor IS NULL OR p_target IS NULL OR p_is_admin IS NULL THEN
    RAISE EXCEPTION USING MESSAGE = 'invalid role change';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_actor) THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_target AND u.email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION USING MESSAGE = 'target user unavailable';
  END IF;

  SELECT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_target)
    INTO v_is_admin;
  IF v_is_admin = p_is_admin THEN
    RETURN false;
  END IF;

  IF p_is_admin THEN
    IF EXISTS (
      SELECT 1 FROM public.customer_profiles p
      WHERE p.user_id = p_target AND p.account_status <> 'active'
    ) THEN
      RAISE EXCEPTION USING MESSAGE = 'target account is not active';
    END IF;
    INSERT INTO private.bank_admins(user_id) VALUES (p_target) ON CONFLICT (user_id) DO NOTHING;
  ELSE
    IF p_actor = p_target THEN
      RAISE EXCEPTION USING MESSAGE = 'self demotion is not allowed';
    END IF;
    SELECT count(*) INTO v_admin_count FROM private.bank_admins;
    IF v_admin_count <= 1 THEN
      RAISE EXCEPTION USING MESSAGE = 'last administrator cannot be removed';
    END IF;
    DELETE FROM private.bank_admins WHERE user_id = p_target;
  END IF;
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.meunova_set_bank_admin_role(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.meunova_set_bank_admin_role(uuid, uuid, boolean) TO service_role;
