import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") || "";
const cors = {
  "Access-Control-Allow-Origin": "https://mahatbazar.github.io",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};
function reply(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { ...cors, "Content-Type": "application/json" } });
}
function cleanText(value: unknown, max = 5000) {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "শুধু POST অনুরোধ গ্রহণযোগ্য।" }, 405);
  try {
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!token) return reply({ error: "Admin login session পাওয়া যায়নি।" }, 401);
    if (!ANON_KEY) return reply({ error: "Admin যাচাইয়ের কনফিগারেশন পাওয়া যায়নি।" }, 503);
    const userDb = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: "Bearer " + token } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userDb.auth.getUser();
    if (authError || !authData.user) return reply({ error: "Admin login যাচাই করা যায়নি। আবার Login করুন।" }, 401);
    const { data: profile, error: profileError } = await userDb.from("profiles").select("role").eq("id", authData.user.id).maybeSingle();
    if (profileError) return reply({ error: "Admin অনুমতি যাচাই করা যায়নি: " + cleanText(profileError.message, 180) }, 403);
    if (!["admin", "sub_admin"].includes(profile?.role || "")) return reply({ error: "শুধু Admin এই সুবিধা ব্যবহার করতে পারবেন।" }, 403);
    if (!GEMINI_API_KEY) return reply({ error: "AI চালু করতে Supabase Edge Function Secret-এ GEMINI_API_KEY যোগ করতে হবে।" }, 503);

    const body = await req.json();
    const productName = cleanText(body.product_name, 200);
    const mimeType = cleanText(body.mime_type, 80);
    const imageBase64 = cleanText(body.image_base64, 8000000);
    const hasImage = Boolean(imageBase64 && /^image\/(jpeg|png|webp|heic|heif)$/i.test(mimeType));
    if (!productName && !hasImage) return reply({ error: "পণ্যের নাম লিখুন অথবা একটি ছবি নির্বাচন করুন।" }, 400);
    if (imageBase64 && !hasImage) return reply({ error: "JPG, PNG বা WebP ছবি ব্যবহার করুন।" }, 400);
    if (imageBase64.length > 7000000) return reply({ error: "ছবিটি খুব বড়। ৫ MB-এর মধ্যে ছবি দিন।" }, 400);
    const categories = Array.isArray(body.categories) ? body.categories.slice(0, 60).map((c: any) => ({ id: cleanText(c?.id, 80), name: cleanText(c?.name, 100), name_bn: cleanText(c?.name_bn, 100) })) : [];
    const categoryList = categories.map((c) => c.name_bn + " / " + c.name).join("\n");

    const prompt = "You are Hatbazar Bangladesh marketplace's careful ecommerce catalog writer. Return ONLY valid JSON.\n" +
      (productName ? "Product name supplied by the admin: " + productName + ". Identify the most likely exact food/product, and if ambiguous do not invent details.\n" : "Identify the product only from visible evidence in the uploaded photo.\n") +
      "Write polished, useful Bangladeshi Bengali and clear retail English. Never invent brand, model, origin, material, nutrition values, certification, medical benefits, or specifications. If uncertain, say so or omit.\n" +
      "If this is food, also provide: evidence-based general nutrition context, realistic potential benefits linked to known nutrients, common ways to eat/use it, sensible general serving guidance only when well established, allergy/storage cautions. Do NOT claim it cures, treats, prevents, or controls any disease. Do not make guaranteed health promises. Do not fabricate exact calories, vitamins, minerals, or serving sizes. Clearly distinguish general nutrition information from medical advice. If the product name is a blend (for example cashew honey), do not assume ingredients or proportions not supplied. For every food product, nutrition_bn MUST contain at least 10 distinct, useful Bengali bullet points, and nutrition_en must contain the matching English points. Cover relevant nutrients and composition (for example energy, carbohydrates, protein, fats, fiber, natural sugars, vitamins, minerals, water content, and notable bioactive compounds only where genuinely relevant). Explain what each nutrient contributes in general terms. Do not pad with repeated or irrelevant points. Never invent numeric amounts. Give amounts only when reliably established for the exact food and state the basis (such as per 100 g); otherwise describe qualitatively and note that values vary by variety and preparation. If fewer than 10 reliable product-specific facts are available, use clearly labeled general nutrient-context points without pretending they are measured values.\n" +
      "If it is not food, food-specific fields must be empty arrays/strings.\n" +
      "Choose exactly one best matching category from this database list, or empty category_name if none fits:\n" + categoryList + "\n" +
      'Return JSON: {"name":"English title","name_bn":"Bengali title","description_en":"2-4 sentence description","description_bn":"2-4 sentence Bengali description","features_en":["3-6 evidence-based features"],"features_bn":["same in Bengali"],"category_name":"exact English category or empty","product_type":"short type","attributes":{},"sizes":[],"is_food":false,"nutrition_bn":["general nutrition facts without invented numbers"],"benefits_bn":["realistic nutrient-linked potential benefits, no medical claims"],"how_to_eat_bn":["practical ways to eat/use"],"cautions_bn":["allergy, moderation, storage or other relevant cautions"],"nutrition_en":["English equivalents"],"benefits_en":["English equivalents"],"how_to_eat_en":["English equivalents"],"cautions_en":["English equivalents"]}.\n' +
      'For sizes: apparel may have S-XXL; only add numeric sizes when genuinely relevant. Do not invent prices or stock.';

    const parts: any[] = [{ text: prompt }];
    if (hasImage) parts.push({ inline_data: { mime_type: mimeType, data: imageBase64 } });
    let finalApiResponse: Response | null = null;
    const quotaModels: string[] = [];
    const models = hasImage
      ? ["gemini-3.8-flash", "gemini-3.5-flash-lite"]
      : ["gemini-3.5-flash-lite", "gemini-3.8-flash"];
    for (const model of models) {
      for (let attempt = 0; attempt < 2; attempt++) {
        const candidate = await fetch("https://generativelanguage.googleapis.com/v1beta/models/" + model + ":generateContent?key=" + encodeURIComponent(GEMINI_API_KEY), {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ contents: [{ parts }], generationConfig: { thinkingConfig: { thinkingLevel: "LOW" }, maxOutputTokens: 2400, responseMimeType: "application/json" } })
        });
        if (candidate.ok) { finalApiResponse = candidate; break; }
        const errBody = await candidate.clone().json().catch(() => ({}));
        const errText = cleanText(errBody?.error?.message, 700);
        const isQuota = candidate.status === 429 && (
          JSON.stringify(errBody).includes("generate_content_free_tier_requests") ||
          JSON.stringify(errBody).includes("generate_content_free_tier_input_token_count") ||
          /quota|resource_exhausted/i.test(errText)
        );
        if (isQuota) {
          quotaModels.push(model);
          console.warn("Hatbazar direct AI quota exhausted; switching model", model);
          break;
        }
        if (candidate.status === 404 || candidate.status === 503 || candidate.status >= 500) {
          if (attempt === 0 && candidate.status !== 404) { await new Promise(resolve => setTimeout(resolve, 1000)); continue; }
          break;
        }
        return reply({ error: errText || "AI থেকে তথ্য তৈরি করা যায়নি।" }, 502);
      }
      if (finalApiResponse?.ok) break;
    }
    if (!finalApiResponse?.ok) {
      if (quotaModels.length) return reply({ error: "Gemini Free quota শেষ। বিকল্প মডেলেও এই অনুরোধ সম্পন্ন হয়নি। Quota reset হলে আবার চেষ্টা করুন।" }, 429);
      return reply({ error: "Gemini AI মডেলগুলো এখন সাড়া দিচ্ছে না। পরে আবার চেষ্টা করুন।" }, 503);
    }
    const aiResult = await finalApiResponse.json();
    if (!finalApiResponse.ok) {
      if (finalApiResponse.status === 503) return reply({ error: "Google Gemini সার্ভার এখন ব্যস্ত। ২ বার স্বয়ংক্রিয় চেষ্টা করেও উত্তর পাওয়া যায়নি। ১-২ মিনিট পরে আবার চেষ্টা করুন।" }, 503);
      return reply({ error: cleanText(aiResult?.error?.message, 400) || "AI থেকে তথ্য তৈরি করা যায়নি।" }, 502);
    }
    const raw = aiResult?.candidates?.[0]?.content?.parts?.map((p: any) => p.text || "").join("") || "";
    let parsed: any;
    try { parsed = JSON.parse(raw); } catch { return reply({ error: "AI-এর উত্তর সঠিকভাবে পড়া যায়নি। আবার চেষ্টা করুন।" }, 502); }

    const allowed = categories.find((c: any) => c.name.toLowerCase() === cleanText(parsed.category_name, 100).toLowerCase());
    const validSizes = new Set(["S","M","L","XL","XXL","30","31","32","33","34","35","36"]);
    const sizes = Array.isArray(parsed.sizes) ? parsed.sizes.map((s: any) => String(s).toUpperCase()).filter((s: string) => validSizes.has(s)) : [];
    const attributes = parsed.attributes && typeof parsed.attributes === "object" && !Array.isArray(parsed.attributes) ? parsed.attributes : {};
    const categoryId = allowed?.id || null;



    const arr = (v: any) => Array.isArray(v) ? v.map((x: unknown) => cleanText(x, 350)).filter(Boolean).slice(0, 16) : [];
    return reply({
      name: cleanText(parsed.name, 200) || productName, name_bn: cleanText(parsed.name_bn, 200),
      description_en: cleanText(parsed.description_en, 3000), description_bn: cleanText(parsed.description_bn, 3000),
      features_en: arr(parsed.features_en).slice(0, 6), features_bn: arr(parsed.features_bn).slice(0, 6),
      nutrition_bn: arr(parsed.nutrition_bn), benefits_bn: arr(parsed.benefits_bn), how_to_eat_bn: arr(parsed.how_to_eat_bn), cautions_bn: arr(parsed.cautions_bn),
      nutrition_en: arr(parsed.nutrition_en), benefits_en: arr(parsed.benefits_en), how_to_eat_en: arr(parsed.how_to_eat_en), cautions_en: arr(parsed.cautions_en),
      is_food: parsed.is_food === true,
      category_id: categoryId, category_name: allowed?.name || "",
      product_type: cleanText(parsed.product_type, 100), attributes, sizes
    });
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : "AI অনুরোধ ব্যর্থ হয়েছে।" }, 500);
  }
});