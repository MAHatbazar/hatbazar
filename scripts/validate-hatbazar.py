from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
html = (root / "index.html").read_text(encoding="utf-8")
step7 = (root / "supabase/hatbazar_step7_order_safety.sql").read_text(encoding="utf-8")
step9 = (root / "supabase/hatbazar_step9_district_validation.sql").read_text(encoding="utf-8")
step10 = (root / "supabase/hatbazar_step10_rate_limits.sql").read_text(encoding="utf-8")

checks = {
    "checkout uses the server-side checkout RPC": "rpc('hatbazar_checkout_v2'" in html,
    "guest order tracking uses the protected lookup RPC": "rpc('hatbazar_lookup_order'" in html,
    "online payment transaction reference is sent to checkout": "p_payment_trx_id: orderRecord.paymentTrxId || null" in html,
    "reseller checkout identity comes from the signed-in Supabase user": "p_reseller_id: supabaseProfile?.role === 'reseller' ? (supabaseUser?.id || null) : null" in html,
    "checkout SQL ignores the client delivery fee and reads protected settings": "The submitted client fee is ignored" in step7 and "public.hatbazar_delivery_settings" in step7,
    "checkout SQL locks product rows before stock changes": "FOR UPDATE" in step7 and "UPDATE public.products" in step7,
    "district migration includes server-side district validation": "Unsupported Bangladesh district" in step9,
    "rate-limit identifiers are hashed before persistence": "extensions.digest" in step10 and "key_hash" in step10,
    "rate-limit table is not directly accessible to API roles": "REVOKE ALL ON TABLE private.hatbazar_rate_limits FROM PUBLIC, anon, authenticated, service_role" in step10,
    "checkout and lookup have separate server-side limits": "'checkout'" in step10 and "'order_lookup'" in step10 and "Too many checkout attempts" in step10 and "Too many order lookup attempts" in step10,
    "no Supabase service-role or secret key is embedded in the storefront": re.search(r"service_role|sb_secret_[A-Za-z0-9]+", html, re.I) is None,
}

failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL") + ": " + name)
if failed:
    print(f"\\n{len(failed)} Hatbazar regression check(s) failed.", file=sys.stderr)
    raise SystemExit(1)
print(f"\\nAll {len(checks)} Hatbazar regression checks passed.")
