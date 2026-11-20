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
    "admin and live-editor navigation are hidden until an authenticated admin session": "adminNav.style.display = adminActive ? '' : 'none'" in html and "editorNav.style.display = adminActive ? '' : 'none'" in html,
    "direct navigation to admin-only management views is guarded": "adminOnlyViews.includes(viewName) && !isAdminSession()" in html and "Admin access only" in html,
    "home hero uses a real retail photograph": "photo-1441986300917-64674bd600d8" in html and "Real clothing and lifestyle retail store interior" in html,
    "shipping, return and refund policy cards include relevant photos": "Shipping parcels ready for delivery" in html and "Shopping bag and customer return experience" in html and "Digital refund and payment card" in html,
    "public navigation contains only home, categories, seller registration and reseller registration": all(token in html for token in ["data-nav=" + chr(34) + "home" + chr(34), "data-nav=" + chr(34) + "shop" + chr(34), "data-nav=" + chr(34) + "sellerRegistration" + chr(34), "data-nav=" + chr(34) + "resellerRegistration" + chr(34)]) and "data-nav=" + chr(34) + "sellerDash" + chr(34) not in html and "data-nav=" + chr(34) + "ordersHistory" + chr(34) not in html,
    "seller and reseller registration buttons preselect the matching application type": "openPartnerRegistration('seller')" in html and "openPartnerRegistration('reseller')" in html and "roleSelect.value = role" in html,
    "management routes are restricted to authenticated admin sessions": "const adminOnlyViews = ['admin', 'sellerDash', 'resellerDash', 'ordersHistory', 'liveEditor']" in html and "adminOnlyViews.includes(viewName) && !isAdminSession()" in html,
    "admin dashboard provides shortcuts to private management sections": all("navigateTo('" + view + "')" in html for view in ["sellerDash", "resellerDash", "ordersHistory", "policies", "liveEditor"]),
    "mobile storefront has a fixed four-item customer navigation": 'id="mobileCustomerNav"' in html and 'data-mobile-nav="home"' in html and 'data-mobile-nav="shop"' in html and 'data-mobile-nav="sellerRegistration"' in html and 'data-mobile-nav="resellerRegistration"' in html,
    "category add and remove controls exist only in the admin dashboard": 'id="adminCategoryAdjustTitle"' not in html and html.index('id="adminView"') < html.index('id="adminAddCategoryBtn"'),
    "folder product creation form is hidden by default for customers": 'id="folderSideAddColumn" class="hidden' in html and "adminFolderControls.forEach" in html and "el.classList.toggle('hidden', !adminActive)" in html,
    "folder cover upload and category rename controls are hidden for customers": 'id="inlineFolderAdminUploadBar" class="hidden' in html and 'id="adminRenameCategoryBtn"' in html and 'class="hidden px-2.5 py-1 rounded-lg' in html,
    "hero live editor action is hidden unless an admin session is active": 'id="heroLiveEditorBtn"' in html and "heroEditorButton.classList.toggle('hidden', !adminActive)" in html,
    "mobile navigation is hidden on admin management screens": "mobileCustomerNav.classList.toggle('hidden', adminOnlyViews.includes(currentView))" in html,
    "Hatbazar favicon uses the branded shopping bag mark": "M18 25h28" in html and "fill='%234c1d95'" in html,
    "seller and reseller applications no longer report fake local-only success": "sellerPartnersData.unshift({" not in html and "pendingHatbazarPartnerApplication" in html,
    "partner application details are persisted through the authenticated v2 RPC": "hatbazar_register_marketplace_profile_v2" in html and "p_shop_name: partnerApplication.shop_name || name" in html and "p_district: partnerApplication.district || ''" in html,
    "partner form collects account credentials before claiming submission": "window.pendingHatbazarPartnerApplication = {" in html and "authModal" in html and "complete করুন" in html,
    "partner registration metadata survives email confirmation": "hatbazar_partner_application: window.pendingHatbazarPartnerApplication" in html and "supabaseUser.user_metadata?.hatbazar_partner_application" in html,

}

failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL") + ": " + name)
if failed:
    print(f"\\n{len(failed)} Hatbazar regression check(s) failed.", file=sys.stderr)
    raise SystemExit(1)
print(f"\\nAll {len(checks)} Hatbazar regression checks passed.")
