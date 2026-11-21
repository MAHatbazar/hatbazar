import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const META_APP_ID = "29103743172619325";
const META_APP_SECRET = Deno.env.get("META_APP_SECRET")!;
const PAGE_ID = "506957092511587";
const GRAPH = "https://graph.facebook.com/v27.0";
const SITE_URL = "https://mahatbazar.github.io/hatbazar/";
const REDIRECT_URI = `${SUPABASE_URL}/functions/v1/hatbazar-facebook?action=callback`;
const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const cors = {
  "Access-Control-Allow-Origin": "https://mahatbazar.github.io",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Vary": "Origin",
};

function reply(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
function redirect(url: string) {
  return Response.redirect(url, 302);
}
async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map(x => x.toString(16).padStart(2, "0")).join("");
}
function randomState() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return Array.from(bytes).map(x => x.toString(16).padStart(2, "0")).join("");
}

function decodeBase64(value: string) {
  const binary = atob(value);
  return Uint8Array.from(binary, c => c.charCodeAt(0));
}
function encodeBase64(value: Uint8Array) {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary);
}
async function tokenCryptoKey() {
  const encoded = Deno.env.get("META_TOKEN_ENCRYPTION_KEY") || "";
  const raw = decodeBase64(encoded);
  if (raw.length !== 32) throw new Error("Facebook token encryption key is not configured correctly.");
  return await crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}
async function encryptPageToken(token: string) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await tokenCryptoKey(), new TextEncoder().encode(token));
  return "enc:v1:" + encodeBase64(new Uint8Array([...iv, ...new Uint8Array(encrypted)]));
}
async function decryptPageToken(value: string) {
  if (!value.startsWith("enc:v1:")) throw new Error("Stored Facebook token is not encrypted. Reconnect the Page to secure it.");
  const packed = decodeBase64(value.slice(7));
  const iv = packed.slice(0, 12);
  const ciphertext = packed.slice(12);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, await tokenCryptoKey(), ciphertext);
  return new TextDecoder().decode(plain);
}
async function requireAdmin(req: Request, allowSubAdmin = false) {
  const auth = req.headers.get("Authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) throw new Error("Admin login required.");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || "";
  if (!anonKey) throw new Error("Supabase public API key is not configured for admin verification.");
  const userDb = createClient(SUPABASE_URL, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: { user }, error: userError } = await userDb.auth.getUser(token);
  if (userError || !user) throw new Error("Login session is invalid. Please sign in again.");
  const { data: profile, error } = await userDb.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (error) throw new Error("Admin profile check failed: " + error.message);
  if (profile?.role !== "admin" && !(allowSubAdmin && profile?.role === "sub_admin")) throw new Error("This signed-in account does not have the required Hatbazar staff role.");
  return user;
}
async function graphGet(path: string, params: Record<string, string>) {
  const url = new URL(`${GRAPH}/${path}`);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const res = await fetch(url);
  const data = await res.json();
  if (!res.ok || data.error) { console.error("META_GRAPH_ERROR", path, JSON.stringify({status:res.status, error:data.error ? {message:data.error.message, type:data.error.type, code:data.error.code, error_subcode:data.error.error_subcode} : null})); throw new Error(data.error?.message || "Meta API request failed."); }
  return data;
}
async function callback(req: Request) {
  const u = new URL(req.url);
  const code = u.searchParams.get("code");
  const state = u.searchParams.get("state");
  if (u.searchParams.has("error") || !code || !state) {
    return redirect("https://mahatbazar.github.io/hatbazar/admin/?facebook=cancelled");
  }
  const stateHash = await sha256(state);
  const { data: used, error: stateError } = await db.from("hatbazar_meta_oauth_states")
    .delete().eq("state_hash", stateHash).gt("expires_at", new Date().toISOString())
    .select("state_hash").maybeSingle();
  if (stateError || !used) {
    return redirect("https://mahatbazar.github.io/hatbazar/admin/?facebook=state_error");
  }

  const tokenUrl = new URL(`${GRAPH}/oauth/access_token`);
  tokenUrl.searchParams.set("client_id", META_APP_ID);
  tokenUrl.searchParams.set("client_secret", META_APP_SECRET);
  tokenUrl.searchParams.set("redirect_uri", REDIRECT_URI);
  tokenUrl.searchParams.set("code", code);
  const shortRes = await fetch(tokenUrl);
  const shortData = await shortRes.json();
  if (!shortRes.ok || !shortData.access_token) {
    console.error("META_SHORT_TOKEN_ERROR", JSON.stringify({
      status: shortRes.status,
      error: shortData.error ? {
        message: shortData.error.message,
        type: shortData.error.type,
        code: shortData.error.code,
        error_subcode: shortData.error.error_subcode
      } : null
    }));
    return redirect("https://mahatbazar.github.io/hatbazar/admin/?facebook=token_error");
  }

  const longData = await graphGet("oauth/access_token", {
    grant_type: "fb_exchange_token",
    client_id: META_APP_ID,
    client_secret: META_APP_SECRET,
    fb_exchange_token: shortData.access_token,
  });
  const pages = await graphGet("me/accounts", {
    fields: "id,name,access_token,tasks",
    access_token: longData.access_token,
  });
  const page = (pages.data || []).find((p: any) =>
    String(p.id) === PAGE_ID && typeof p.access_token === "string" && p.access_token.length > 0);
  if (!page?.access_token) {
    const target = (pages.data || []).find((p: any) => p.id === PAGE_ID);
    console.error("META_PAGE_ACCESS_ERROR", JSON.stringify({
      returnedPageCount: Array.isArray(pages.data) ? pages.data.length : 0,
      returnedPages: (pages.data || []).map((p: any) => ({
        id: String(p.id || ""),
        name: String(p.name || ""),
        tasks: Array.isArray(p.tasks) ? p.tasks : []
      })),
      expectedPageId: PAGE_ID,
      targetPageFound: !!target,
      targetPageTasks: Array.isArray(target?.tasks) ? target.tasks : []
    }));
    return redirect("https://mahatbazar.github.io/hatbazar/admin/?facebook=page_access_error");
  }
  const { error } = await db.from("hatbazar_meta_page_connection").upsert({
    id: 1, page_id: PAGE_ID, page_name: page.name || "Hatbazar",
    page_access_token: await encryptPageToken(page.access_token), connected_at: new Date().toISOString(),
  });
  if (error) { console.error("META_CONNECTION_SAVE_ERROR", error.message); return redirect("https://mahatbazar.github.io/hatbazar/admin/?facebook=save_error"); }
  return redirect("https://mahatbazar.github.io/hatbazar/admin/?facebook=connected");
}

async function publishProduct(req: Request) {
  await requireAdmin(req, true);
  const body = await req.json().catch(() => ({}));
  const productId = String(body.product_id || "");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(productId)) {
    return reply({ error: "Invalid product ID." }, 400);
  }
  const { data: connection, error: connectionError } = await db.from("hatbazar_meta_page_connection")
    .select("page_id,page_access_token").eq("id", 1).maybeSingle();
  if (connectionError || !connection) return reply({ error: "Facebook Page is not connected yet." }, 409);

  const { data: product, error: productError } = await db.from("products")
    .select("id,name,name_bn,description,price,is_active,image_url")
    .eq("id", productId).maybeSingle();
  if (productError || !product || !product.is_active) return reply({ error: "Active product not found." }, 404);

  const { data: gallery, error: galleryError } = await db.from("product_images")
    .select("image_url").eq("product_id", productId).order("sort_order", { ascending: true }).limit(10);
  if (galleryError) return reply({ error: "Product images could not be loaded." }, 500);
  const images = [...new Set([...(gallery || []).map((x: any) => x.image_url), product.image_url].filter(Boolean))].slice(0, 10);
  if (!images.length) return reply({ error: "Add at least one public product image before Facebook posting." }, 400);

  const { data: prior } = await db.from("hatbazar_facebook_posts").select("facebook_post_id")
    .eq("product_id", productId).maybeSingle();
  if (prior) return reply({ error: "This product has already been posted to Facebook." }, 409);

  const pageAccessToken = await decryptPageToken(connection.page_access_token);
  const title = product.name_bn || product.name || "Hatbazar Product";
  const caption = [
    `🛍️ ${title}`,
    product.name && product.name_bn ? product.name : "",
    `মূল্য: ৳${Number(product.price || 0).toLocaleString("en-BD")}`,
    product.description || "",
    "অর্ডার করতে ভিজিট করুন: " + SITE_URL,
    "#Hatbazar #OnlineShopping #Bangladesh",
  ].filter(Boolean).join("\n\n");

  let postId = "";
  if (images.length === 1) {
    const form = new URLSearchParams({
      url: images[0], caption, published: "true", access_token: pageAccessToken,
    });
    const res = await fetch(`${GRAPH}/${connection.page_id}/photos`, { method: "POST", body: form });
    const data = await res.json();
    if (!res.ok || data.error) return reply({ error: data.error?.message || "Facebook photo post failed." }, 502);
    postId = data.post_id || data.id;
  } else {
    const mediaIds: string[] = [];
    for (const imageUrl of images) {
      const form = new URLSearchParams({ url: imageUrl, published: "false", access_token: pageAccessToken });
      const res = await fetch(`${GRAPH}/${connection.page_id}/photos`, { method: "POST", body: form });
      const data = await res.json();
      if (!res.ok || data.error || !data.id) return reply({ error: data.error?.message || "Facebook image upload failed." }, 502);
      mediaIds.push(data.id);
    }
    const form = new URLSearchParams({ message: caption, access_token: pageAccessToken });
    mediaIds.forEach((id, i) => form.set(`attached_media[${i}]`, JSON.stringify({ media_fbid: id })));
    const res = await fetch(`${GRAPH}/${connection.page_id}/feed`, { method: "POST", body: form });
    const data = await res.json();
    if (!res.ok || data.error || !data.id) return reply({ error: data.error?.message || "Facebook post failed." }, 502);
    postId = data.id;
  }
  const { error: logError } = await db.from("hatbazar_facebook_posts").insert({
    product_id: productId, facebook_post_id: postId,
  });
  if (logError) return reply({ error: "Post published, but its confirmation could not be saved. Do not retry immediately." }, 500);
  return reply({ ok: true, post_id: postId, message: "Facebook post published." });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = new URL(req.url);
  const action = url.searchParams.get("action") || "";
  try {
    if (action === "status" && req.method === "GET") {
      await requireAdmin(req);
      const { data, error } = await db.from("hatbazar_meta_page_connection")
        .select("page_id,page_name,connected_at").eq("id", 1).maybeSingle();
      if (error) return reply({ error: "Facebook connection status could not be loaded." }, 500);
      return reply({
        configured: !!META_APP_SECRET && !!Deno.env.get("META_TOKEN_ENCRYPTION_KEY"),
        connected: !!data,
        page_name: data?.page_name || null,
        connected_at: data?.connected_at || null
      });
    }
    if (action === "callback" && req.method === "GET") {
      if (!META_APP_SECRET) return redirect("https://mahatbazar.github.io/hatbazar/admin/?facebook=server_config_error");
      return await callback(req);
    }
    if (action === "connect" && req.method === "POST") {
      await requireAdmin(req);
      if (!META_APP_SECRET) return reply({ error: "Facebook server secret is not configured." }, 503);
      const state = randomState();
      const { error } = await db.from("hatbazar_meta_oauth_states").insert({
        state_hash: await sha256(state),
        expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
      });
      if (error) throw new Error("Could not start secure Facebook connection.");
      const authUrl = new URL("https://www.facebook.com/v27.0/dialog/oauth");
      authUrl.searchParams.set("client_id", META_APP_ID);
      authUrl.searchParams.set("redirect_uri", REDIRECT_URI);
      authUrl.searchParams.set("response_type", "code");
      authUrl.searchParams.set("state", state);
      authUrl.searchParams.set("scope", "pages_show_list,pages_read_engagement,pages_manage_posts");
      return reply({ url: authUrl.toString() });
    }
    if (action === "publish" && req.method === "POST") return await publishProduct(req);
    return reply({ error: "Unsupported action." }, 404);
  } catch (e) {
    return reply({ error: e instanceof Error ? e.message : "Unexpected server error." }, 400);
  }
});