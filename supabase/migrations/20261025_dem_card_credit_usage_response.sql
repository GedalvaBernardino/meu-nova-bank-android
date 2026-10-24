-- Replaces the active DEM transfer RPC with a card-usage response contract.
-- The sender profile row is locked before validation/update. The card increment,
-- recipient credit, ledger entries and idempotency record commit atomically.
-- Replays return the stored result and never increment card usage again.
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
  v_card_used_after numeric(12,2);
  v_card_available_after numeric(12,2);
  v_demo_card_active boolean;
  v_demo_card_expires_on date;
  v_overdraft_limit numeric(12,2);
  v_overdraft_used numeric(12,2);
  v_overdraft_active boolean;
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
     OR p_funding_source IS NULL OR p_funding_source NOT IN ('balance', 'card', 'overdraft') THEN
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
  SELECT p.account_number,p.display_name,p.account_status,p.card_credit_limit,p.card_credit_used,p.demo_card_active,p.demo_card_expires_on,p.overdraft_user_limit,p.overdraft_used,p.overdraft_active
    INTO v_sender_account,v_sender_name,v_sender_status,v_card_limit,v_card_used,v_demo_card_active,v_demo_card_expires_on,v_overdraft_limit,v_overdraft_used,v_overdraft_active
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
  v_card_used_after := COALESCE(v_card_used,0);
  IF p_funding_source='card' THEN
    IF NOT v_demo_card_active OR v_demo_card_expires_on IS NULL OR v_demo_card_expires_on < CURRENT_DATE THEN RAISE EXCEPTION USING MESSAGE='demo card is blocked or expired'; END IF;
    v_fee:=round(p_amount*0.037,2); v_charge:=p_amount+v_fee;
    IF v_card_limit<152 OR v_card_used+v_charge>v_card_limit THEN
      RAISE EXCEPTION USING MESSAGE='card limit insufficient for transfer plus fee';
    END IF;
    UPDATE public.customer_profiles
      SET card_credit_used=card_credit_used+v_charge,updated_at=now()
      WHERE user_id=v_user_id
      RETURNING card_credit_used INTO v_card_used_after;
    IF NOT FOUND OR v_card_used_after IS NULL THEN
      RAISE EXCEPTION USING MESSAGE='card credit usage update failed';
    END IF;
  ELSIF p_funding_source='overdraft' THEN
    IF NOT v_overdraft_active THEN RAISE EXCEPTION USING MESSAGE='DEM_OVERDRAFT_INACTIVE'; END IF;
    IF COALESCE(v_overdraft_used,0)+p_amount > COALESCE(v_overdraft_limit,0) THEN RAISE EXCEPTION USING MESSAGE='DEM_OVERDRAFT_LIMIT_INSUFFICIENT'; END IF;
    UPDATE public.customer_profiles SET overdraft_used=overdraft_used+p_amount,updated_at=now() WHERE user_id=v_user_id;
  ELSE
    SELECT w.available_balance INTO v_balance FROM public.wallets w WHERE w.user_id=v_user_id FOR UPDATE;
    IF NOT FOUND OR COALESCE(v_balance,0)<p_amount THEN RAISE EXCEPTION USING MESSAGE='insufficient balance'; END IF;
    UPDATE public.wallets SET available_balance=available_balance-p_amount,updated_at=now() WHERE user_id=v_user_id;
  END IF;
  v_card_available_after := GREATEST(COALESCE(v_card_limit,0)-v_card_used_after,0);
  UPDATE public.wallets SET available_balance=available_balance+p_amount,updated_at=now() WHERE user_id=v_recipient_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING MESSAGE='recipient wallet not found'; END IF;
  v_result:=jsonb_build_object('ok',true,'status','posted','operation_id',p_request_id,
    'sender_account',v_sender_account,'recipient_account',p_recipient_account,'recipient_name',v_recipient_name,
    'amount',p_amount,'funding_source',p_funding_source,
    'fee_rate',CASE WHEN p_funding_source='card' THEN 0.037 ELSE 0 END,
    'fee_amount',v_fee,'charged_amount',v_charge,'balances_updated',p_funding_source='balance',
    'card_demo_usage_updated',p_funding_source='card',
    'card_credit_limit',v_card_limit,'card_credit_used',v_card_used_after,'card_credit_available',v_card_available_after,
    'overdraft_used',CASE WHEN p_funding_source='overdraft' THEN v_overdraft_used+p_amount ELSE v_overdraft_used END,'overdraft_remaining',CASE WHEN p_funding_source='overdraft' THEN GREATEST(v_overdraft_limit-v_overdraft_used-p_amount,0) ELSE GREATEST(v_overdraft_limit-v_overdraft_used,0) END,'overdraft_demo_usage_updated',p_funding_source='overdraft','real_network_used',false);
  INSERT INTO public.operation_requests(id,user_id,operation_type,amount,recipient_reference,status,request_data)
    VALUES(p_request_id,v_user_id,'dem_transfer',p_amount,p_recipient_account,'approved',v_result);
  INSERT INTO public.ledger_entries(user_id,operation_id,entry_type,amount,description,entry_status)
    VALUES(v_user_id,p_request_id,'debit',v_charge,
      CASE WHEN p_funding_source='card' THEN 'Transferência DEM Meu Nova Card · valor + taxa de 3,7%'
        WHEN p_funding_source='overdraft' THEN 'Transferência DEM enviada para conta '||p_recipient_account||' · cheque especial demonstrativo'
        ELSE 'Transferência DEM enviada para conta '||p_recipient_account END,'posted');
  INSERT INTO public.ledger_entries(user_id,operation_id,entry_type,amount,description,entry_status)
    VALUES(v_recipient_id,p_request_id,'credit',p_amount,'Transferência DEM recebida de conta '||v_sender_account,'posted');
  RETURN v_result;
END;
$function$;


REVOKE ALL ON FUNCTION public.meunova_execute_dem_transfer(uuid, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.meunova_execute_dem_transfer(uuid, text, numeric, text) TO authenticated, service_role;
