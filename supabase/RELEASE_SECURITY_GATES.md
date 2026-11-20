# Hatbazar release security gates

This file records security controls that cannot be enabled safely by a source-code-only change.

## Supabase Auth leaked-password protection

The connected Supabase organization is currently on the **Free** plan. Supabase's current Password Security documentation states that leaked-password protection (HaveIBeenPwned Pwned Passwords checks) is available on the **Pro plan and above**.

- Do not claim this setting is enabled on the current project.
- To use this exact control, the project owner must upgrade the Supabase organization to Pro or above, then open **Authentication → Settings → Password Security** in the Supabase Dashboard and enable leaked-password protection.
- This setting cannot be changed through the connected project/database tools.
- Until then, keep this as a release warning. A minimum password length and strong-password requirements are useful but are not equivalent to leaked-password screening.

Reference: https://supabase.com/docs/guides/auth/password-security

## Cloudflare Turnstile

A client-side Turnstile widget by itself is not a security control. The secret must remain server-side, the token must be verified against Cloudflare's Siteverify API, and the public database checkout RPC must not remain an alternate path that bypasses verification.

Required owner-controlled setup:
1. Create a Cloudflare Turnstile widget for the exact production hostname `mahatbazar.github.io` (Managed mode is a reasonable default).
2. Keep the **site key** as public frontend configuration.
3. Store the **secret key** only as a Supabase Edge Function secret, for example `TURNSTILE_SECRET_KEY`. Never put it in `index.html`, GitHub, browser storage, or chat.
4. Route checkout through a server-side verification endpoint and ensure direct public execution of the checkout RPC cannot bypass the verification. Preserve authenticated customer/reseller identity checks when moving the RPC behind an Edge Function.
5. Test valid, missing, expired, replayed, and invalid tokens, plus guest checkout and authenticated reseller checkout, before enabling the new path.

The connected Supabase tools can deploy Edge Functions but do not expose a secret-management action. Do not deploy a function that expects an unavailable secret and then claim Turnstile is active. Do not revoke the current checkout RPC grants until a tested replacement path is ready, or checkout will stop working.

## Current status

- Per-mobile-number database throttling is active (4 successful checkouts and 10 valid-format order lookups per 10 minutes).
- IP-based throttling and CAPTCHA are not active.
- The public checkout RPC remains callable directly, so a frontend-only CAPTCHA would be bypassable.
- Supabase leaked-password protection is unavailable on the current Free plan.
- Keep the PR in Draft and do not merge/deploy until the replacement checkout path and owner-controlled settings are verified.
