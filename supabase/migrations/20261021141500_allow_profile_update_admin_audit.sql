ALTER TABLE private.bank_admin_audit DROP CONSTRAINT bank_admin_audit_action_check;
ALTER TABLE private.bank_admin_audit ADD CONSTRAINT bank_admin_audit_action_check CHECK (action IN (
  'rename', 'hide', 'unhide', 'close', 'account_number_edit', 'interbank_credit',
  'interbank_reject', 'wallet_balance_edit', 'feature_visibility_update', 'profile_update'
));

CREATE OR REPLACE FUNCTION public.meunova_record_admin_action(
  p_actor uuid, p_target uuid, p_action text, p_details jsonb DEFAULT '{}'::jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog, public, private
AS $function$
BEGIN
  IF p_actor IS NULL OR p_action NOT IN (
    'rename', 'hide', 'unhide', 'close', 'account_number_edit', 'interbank_credit',
    'interbank_reject', 'wallet_balance_edit', 'feature_visibility_update', 'profile_update'
  ) OR NOT EXISTS (SELECT 1 FROM private.bank_admins a WHERE a.user_id = p_actor) THEN
    RAISE EXCEPTION USING MESSAGE = 'not authorized';
  END IF;
  INSERT INTO private.bank_admin_audit(actor_user_id, target_user_id, action, details)
  VALUES (p_actor, p_target, p_action, COALESCE(p_details, '{}'::jsonb));
END;
$function$;
