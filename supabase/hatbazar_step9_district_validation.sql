-- Hatbazar step 9: validate district names against the storefront's complete 64-district list.
-- Idempotent: safely skips when the guard is already present.
DO $hatbazar_step9$
DECLARE
  v_definition TEXT;
  v_anchor TEXT := '  v_phone := pg_catalog.regexp_replace(pg_catalog.btrim(p_phone), ''[^0-9]'', '''', ''g'');';
  v_guard TEXT := $guard$  IF pg_catalog.btrim(p_district) <> ALL (ARRAY['ঢাকা', 'চট্টগ্রাম', 'সিলেট', 'রাজশাহী', 'খুলনা', 'বরিশাল', 'রংপুর', 'ময়মনসিংহ', 'কুমিল্লা', 'গাজীপুর', 'নারায়ণগঞ্জ', 'নরসিংদী', 'মানিকগঞ্জ', 'মুন্সীগঞ্জ', 'ফরিদপুর', 'গোপালগঞ্জ', 'মাদারীপুর', 'রাজবাড়ী', 'শরীয়তপুর', 'কিশোরগঞ্জ', 'টাঙ্গাইল', 'জামালপুর', 'নেত্রকোণা', 'শেরপুর', 'বগুড়া', 'জয়পুরহাট', 'নওগাঁ', 'নাটোর', 'চাঁপাইনবাবগঞ্জ', 'পাবনা', 'সিরাজগঞ্জ', 'দিনাজপুর', 'ঠাকুরগাঁও', 'পঞ্চগড়', 'নীলফামারী', 'লালমনিরহাট', 'কুড়িগ্রাম', 'গাইবান্ধা', 'যশোর', 'কুষ্টিয়া', 'ঝিনাইদহ', 'মাগুরা', 'নড়াইল', 'বাগেরহাট', 'সাতক্ষীরা', 'চুয়াডাঙ্গা', 'মেহেরপুর', 'ভোলা', 'পটুয়াখালী', 'বরগুনা', 'ঝালকাঠি', 'পিরোজপুর', 'ব্রাহ্মণবাড়িয়া', 'চাঁদপুর', 'লক্ষ্মীপুর', 'ফেনী', 'নোয়াখালী', 'কক্সবাজার', 'খাগড়াছড়ি', 'রাঙ্গামাটি', 'বান্দরবান', 'মৌলভীবাজার', 'হবিগঞ্জ', 'সুনামগঞ্জ']::TEXT[]) THEN
    RAISE EXCEPTION 'Unsupported Bangladesh district';
  END IF;

$guard$;
BEGIN
  SELECT pg_catalog.pg_get_functiondef('public.hatbazar_checkout_v2(text,text,text,text,jsonb,text,text,text,numeric,text,uuid)'::pg_catalog.regprocedure)
  INTO v_definition;
  IF pg_catalog.strpos(v_definition, 'Unsupported Bangladesh district') > 0 THEN
    RAISE NOTICE 'Step 9 district validation is already installed';
    RETURN;
  END IF;
  IF pg_catalog.strpos(v_definition, v_anchor) = 0 THEN
    RAISE EXCEPTION 'Checkout function definition did not match the audited version; no change applied';
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_anchor, v_guard || v_anchor);
  EXECUTE v_definition;
END;
$hatbazar_step9$;
