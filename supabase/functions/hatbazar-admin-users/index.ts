import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const cors = {
  "Access-Control-Allow-Origin": "https://mahatbazar.github.io",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};
function reply(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { ...cors, "Content-Type": "application/json" } });
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "শুধু POST অনুরোধ গ্রহণযোগ্য।" }, 405);
  try {
    const origin = req.headers.get("origin") || "";
    if (origin && origin !== "https://mahatbazar.github.io") return reply({ error: "এই Origin অনুমোদিত নয়।" }, 403);
    if (!SUPABASE_URL || !ANON_KEY || !SERVICE_KEY) return reply({ error: "Sub Admin service configuration is incomplete." }, 503);
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\\s+/i, "");
    if (!token) return reply({ error: "মূল অ্যাডমিন Login প্রয়োজন।" }, 401);
    const userDb = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: "Bearer " + token } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userDb.auth.getUser(token);
    if (authError || !authData.user) return reply({ error: "Login session সঠিক নয়। আবার Login করুন।" }, 401);
    const { data: callerProfile, error: callerError } = await userDb.from("profiles").select("role").eq("id", authData.user.id).maybeSingle();
    if (callerError || callerProfile?.role !== "admin") return reply({ error: "শুধু মূল Super Admin সাব-অ্যাডমিন পরিচালনা করতে পারবেন।" }, 403);

    const adminDb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
    const body = await req.json().catch(() => ({}));
    const action = typeof body.action === "string" ? body.action : "";
    const { data: profileRows, error: profilesError } = await adminDb.from("profiles")
      .select("id,full_name,created_at").eq("role", "sub_admin").order("created_at", { ascending: false });
    if (profilesError) throw profilesError;
    const { data: authUsers, error: usersError } = await adminDb.auth.admin.listUsers({ page: 1, perPage: 1000 });
    if (usersError) throw usersError;
    const userById = new Map((authUsers.users || []).map((u) => [u.id, u]));

    if (action === "list") {
      const users = (profileRows || []).map((profile) => {
        const authUser = userById.get(profile.id);
        return {
          id: profile.id,
          full_name: profile.full_name || authUser?.user_metadata?.full_name || "",
          email: authUser?.email || "",
          created_at: profile.created_at,
          banned_until: authUser?.banned_until || null,
        };
      });
      return reply({ success: true, users });
    }
    if (action === "invite") {
      const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
      const fullName = typeof body.full_name === "string" ? body.full_name.trim().slice(0, 100) : "";
      if (!/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(email) || email.length > 254 || !fullName) return reply({ error: "সঠিক Email ও নাম লিখুন।" }, 400);
      const { data: invited, error: inviteError } = await adminDb.auth.admin.inviteUserByEmail(email, {
        data: { full_name: fullName, hatbazar_invited_role: "sub_admin" },
      });
      if (inviteError || !invited.user) return reply({ error: inviteError?.message || "Invite তৈরি করা যায়নি।" }, 400);
      const { error: profileError } = await adminDb.from("profiles").upsert({
        id: invited.user.id, full_name: fullName, role: "sub_admin",
      }, { onConflict: "id" });
      if (profileError) {
        await adminDb.auth.admin.deleteUser(invited.user.id);
        throw profileError;
      }
      return reply({ success: true, message: "সাব-অ্যাডমিনের ইমেইলে Invite পাঠানো হয়েছে। তিনি নিজের ইমেইল থেকে নিরাপদে Password সেট করবেন।" });
    }
    if (action === "disable" || action === "enable") {
      const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
      if (!email) return reply({ error: "Email দেওয়া হয়নি।" }, 400);
      const targetProfile = (profileRows || []).find((p) => (userById.get(p.id)?.email || "").toLowerCase() === email);
      if (!targetProfile) return reply({ error: "এই Email-এর সাব-অ্যাডমিন পাওয়া যায়নি।" }, 404);
      const { error: updateError } = await adminDb.auth.admin.updateUserById(targetProfile.id, {
        ban_duration: action === "disable" ? "876000h" : "none",
      });
      if (updateError) throw updateError;
      return reply({ success: true, message: action === "disable" ? "সাব-অ্যাডমিনের Login সাময়িকভাবে বন্ধ হয়েছে।" : "সাব-অ্যাডমিনের Login আবার চালু হয়েছে।" });
    }
    return reply({ error: "অনুমোদিত Action নয়।" }, 400);
  } catch (error) {
    console.error("hatbazar-admin-users:", error);
    return reply({ error: error instanceof Error ? error.message : "Sub Admin request failed." }, 500);
  }
});
