import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GEMINI = Deno.env.get("GEMINI_API_KEY") || "";
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") || "";
const db = createClient(URL, SERVICE, { auth: { persistSession: false } });

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
}
function clean(v: unknown, n = 3000) { return typeof v === "string" ? v.trim().slice(0, n) : ""; }
function b64(bytes: Uint8Array) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
function arr(v: any) { return Array.isArray(v) ? v.map(x => clean(x, 350)).filter(Boolean).slice(0, 16) : []; }

async function analyze(name: string, categories: any[], image?: { mime: string; data: string }, description = "") {
  const categoryList = categories.map(c => clean(c.name_bn, 100) + " / " + clean(c.name, 100)).join("\n");
  const prompt =
    "You are Hatbazar Bangladesh marketplace's careful ecommerce catalog writer. Return ONLY valid JSON.\n" +
    (name ? "Product name supplied by admin: " + name + ". Identify the most likely exact product; if ambiguous do not invent details.\n" : "Identify the product only from visible evidence in the uploaded photo.\n") +
    (description ? "Product description supplied by admin (use it to identify product type and category; ignore seller/site branding): " + clean(description, 5000) + "\n" : "") +
    "Write polished Bangladeshi Bengali and clear retail English. Never invent brand, model, origin, material, nutrition values, certification, medical benefits, or specifications. If uncertain, say so or omit.\n" +
    "If food, provide general nutrition context, realistic nutrient-linked potential benefits, common ways to eat/use, sensible guidance only when well established, and allergy/storage cautions. No cure/treat/prevent/control disease claims. Do not fabricate exact nutrition numbers or serving sizes. For every food product, nutrition_bn MUST contain at least 10 distinct, useful Bengali bullet points and nutrition_en the matching English points. Cover relevant nutrients and composition (energy, carbohydrates, protein, fats, fiber, natural sugars, vitamins, minerals, water content, and notable bioactive compounds only when relevant); explain their general role. No repeated filler, irrelevant facts, or invented numeric amounts. Include numeric amounts only when reliable for the exact food and state basis such as per 100 g; otherwise describe qualitatively and note natural variation. If fewer than 10 reliable product-specific facts exist, clearly label general nutrient-context points rather than presenting them as measured facts. If non-food, food-specific fields must be empty.\n" +
    "First identify the likely brand only when it is explicitly stated or reliably recognizable from the product name. Then infer the actual product type from the full name, model number, and wording. Do not confuse a brand with a product category. For example, Prestige spice grinder belongs in Kitchen and Dining, while a Samsung neckband belongs in Audio and Headphones. Choose the narrowest correct category from the supplied list. If the name is too vague, return empty category_name rather than guessing.\n" +
    "Choose exactly one best matching category from this list, or empty category_name:\n" + categoryList + "\n" +
    'Return JSON: {"name":"English title","name_bn":"Bengali title","brand_name":"brand explicitly supported by the product name, otherwise empty","description_en":"2-4 sentence description","description_bn":"2-4 sentence Bengali description","features_en":["3-6 features"],"features_bn":["same in Bengali"],"category_name":"exact English category or empty","product_type":"short type","attributes":{},"sizes":[],"is_food":false,"nutrition_bn":[],"benefits_bn":[],"how_to_eat_bn":[],"cautions_bn":[],"nutrition_en":[],"benefits_en":[],"how_to_eat_en":[],"cautions_en":[]}. Do not invent prices or stock.';
  const parts: any[] = [{ text: prompt }];
  if (image) parts.push({ inline_data: { mime_type: image.mime, data: image.data } });
  let response: Response | null = null;
  let geminiFailure = "";
  let parsed: any = null;
  let providerUsed = "Gemini";
  const models = image ? ["gemini-3.8-flash", "gemini-3.5-flash-lite"] : ["gemini-3.5-flash-lite", "gemini-3.8-flash"];
  if (GEMINI) {
    for (const model of models) {
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          response = await fetch("https://generativelanguage.googleapis.com/v1beta/models/" + model + ":generateContent?key=" + encodeURIComponent(GEMINI), {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ contents: [{ parts }], generationConfig: { thinkingConfig: { thinkingLevel: "LOW" }, maxOutputTokens: 2200, responseMimeType: "application/json" } }),
            signal: AbortSignal.timeout(35000)
          });
          if (response.ok) break;
          const errBody = await response.clone().json().catch(() => ({}));
          geminiFailure = clean(errBody?.error?.message, 700) || ("Gemini HTTP " + response.status);
          if (response.status >= 500 || response.status === 429 || response.status === 404) {
            if (attempt === 0 && response.status !== 404) { await new Promise(r => setTimeout(r, 1000)); continue; }
          }
          break;
        } catch (e) {
          geminiFailure = e instanceof Error ? e.message : "Gemini network error";
          if (attempt === 0) await new Promise(r => setTimeout(r, 1000));
        }
      }
      if (response?.ok) break;
      response = null;
    }
    if (response?.ok) {
      try {
        const geminiJson = await response.json();
        const raw = geminiJson?.candidates?.[0]?.content?.parts?.map((p: any) => p.text || "").join("") || "";
        try { parsed = JSON.parse(raw); } catch { geminiFailure = "Gemini-এর উত্তর সঠিক JSON নয়।"; }
      } catch (e) {
        geminiFailure = e instanceof Error ? e.message : "Gemini response পড়া যায়নি।";
      }
    }
  } else geminiFailure = "GEMINI_API_KEY কনফিগার করা নেই।";

  // Automatically use OpenAI GPT when Gemini is unavailable or returns invalid JSON.
  if (!parsed && OPENAI_API_KEY) {
    try {
      const userContent: any[] = [{ type: "text", text: prompt }];
      if (image) userContent.push({ type: "image_url", image_url: { url: "data:" + image.mime + ";base64," + image.data } });
      const openaiResponse = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": "Bearer " + OPENAI_API_KEY },
        body: JSON.stringify({ model: "gpt-4.1-mini", messages: [{ role: "user", content: userContent }], response_format: { type: "json_object" }, max_completion_tokens: 2400 }),
        signal: AbortSignal.timeout(45000)
      });
      const openaiJson = await openaiResponse.json().catch(() => ({}));
      if (!openaiResponse.ok) throw new Error(clean(openaiJson?.error?.message, 500) || ("OpenAI HTTP " + openaiResponse.status));
      const openaiRaw = openaiJson?.choices?.[0]?.message?.content || "";
      try { parsed = JSON.parse(openaiRaw); } catch { throw new Error("GPT-এর উত্তর সঠিক JSON নয়।"); }
      providerUsed = "OpenAI GPT";
    } catch (e) {
      const openaiFailure = e instanceof Error ? e.message : "OpenAI request failed";
      throw new Error("Gemini ব্যর্থ হয়েছে (" + geminiFailure.slice(0, 180) + ")। GPT বিকল্পও ব্যর্থ হয়েছে: " + openaiFailure.slice(0, 350));
    }
  }
  if (!parsed) {
    if (!OPENAI_API_KEY) throw new Error("Gemini AI সাড়া দেয়নি। GPT বিকল্প চালু করতে Supabase Edge Function Secret-এ OPENAI_API_KEY যোগ করতে হবে।");
    throw new Error(geminiFailure || "Gemini এবং GPT থেকে উত্তর পাওয়া যায়নি।");
  }
  const p = parsed;
  const normCategory = (v: unknown) => clean(v, 120).normalize("NFKC").replace(/[\u200B-\u200D\uFEFF]/g, "").replace(/[^\p{L}\p{N}]+/gu, " ").trim().toLowerCase();
  const suppliedCategory = normCategory(p.category_name);
  let cat = categories.find(c => [c.name, c.name_bn].some(v => normCategory(v) === suppliedCategory));
  // High-confidence product-name rules override a broad AI guess.
  // This prevents audio products such as neckbands from being filed under Mobile Accessories.
  const titleEvidence = normCategory([name, p.name, p.name_bn].filter(Boolean).join(" "));
  const priorityRules: Array<[RegExp, string]> = [
    [/\b(earbud|earbuds|earphone|earphones|headphone|headphones|speaker|headset|neckband|bluetooth audio|wireless audio|tws)\b|হেডফোন|ইয়ারফোন|স্পিকার|নেকব্যান্ড/, "Audio and Headphones"],
    [/\b(grinder|blender|kettle|cookware|flask|bottle|kitchen|cooker|toaster|chopper|spice|pressure cooker|rice cooker|air fryer|frying pan)\b|রান্নাঘর|গ্রাইন্ডার|ব্লেন্ডার|কেটলি|ফ্লাস্ক|কুকার|মসলা|এয়ার ফ্রায়ার/, "Kitchen and Dining"],
    [/\b(phone case|charger|charging cable|usb cable|power bank|mobile holder|screen protector|phone cover)\b|চার্জার|কেবল|পাওয়ার ব্যাংক|মোবাইল কভার/, "Mobile Accessories"],
    [/\b(smart watch|smartwatch|smart band|fitness tracker|smart gadget)\b|স্মার্ট ওয়াচ|স্মার্ট ব্যান্ড/, "Smart Gadgets"],
    [/\b(watch|wristwatch|jewellery|jewelry|necklace|ring|bracelet)\b|ঘড়ি|জুয়েলারি|নেকলেস|আংটি/, "Watches and Jewellery"],
    [/\b(shoe|shoes|sandal|sneaker|slipper|boot)\b|জুতা|স্যান্ডেল|স্লিপার/, "Shoes and Sandals"],
    [/\b(perfume|body spray|deodorant|attar)\b|পারফিউম|বডি স্প্রে|আতর/, "Perfumes and Body Spray"],
    [/\b(shampoo|hair oil|hair serum|conditioner|hair mask)\b|শ্যাম্পু|হেয়ার অয়েল|চুলের তেল/, "Hair Care"],
    [/\b(face wash|moisturizer|sunscreen|skin serum|skin care|face cream)\b|ফেসওয়াশ|ময়েশ্চারাইজার|সানস্ক্রিন|স্কিন কেয়ার/, "Skin Care"],
    [/\b(bag|backpack|luggage|wallet|suitcase)\b|ব্যাগ|লাগেজ|ওয়ালেট/, "Bags and Luggage"],
    [/\b(baby|diaper|feeding bottle|baby lotion|baby care)\b|বেবি|ডায়াপার|শিশু/, "Baby Care"],
    [/\b(book|notebook|stationery|pen|pencil|marker)\b|বই|খাতা|কলম|স্টেশনারি/, "Books and Stationery"],
    [/\b(sofa|curtain|wall decor|lamp|home decor|showpiece)\b|ঘর সাজানো|পর্দা|ল্যাম্প|হোম ডেকর/, "Home Decor"],
    [/\b(honey|rice|mustard oil|grocery|organic food|dates|lentil|spice powder)\b|মধু|চাল|খাবার|গ্রোসারি|ডাল/, "Grocery and Organic"],
    [/\b(panjabi|mens shirt|men shirt|mens t shirt|men t shirt|men clothing)\b|পুরুষদের পোশাক|পাঞ্জাবি/, "Mens Fashion"],
    [/\b(saree|sari|kurti|womens dress|women dress|three piece|ladies clothing)\b|নারীদের পোশাক|শাড়ি|থ্রি পিস/, "Womens Fashion"],
    [/\b(sports|fitness|gym|yoga|dumbbell|football|cricket bat)\b|ব্যায়াম|ফিটনেস|জিম/, "Sports and Fitness"],
    [/\b(travel|camping|outdoor|tent|travel pillow)\b|ভ্রমণ|ক্যাম্পিং|আউটডোর/, "Travel and Outdoor"],
    [/\b(toy|doll|kids wear|children clothing|puzzle)\b|খেলনা|শিশুদের পোশাক/, "Kids Collection"],
    [/\b(gift box|gift hamper|gift set)\b|গিফট বক্স|উপহারের সেট/, "Gifts and Hampers"],
    [/\b(eid|festive|ethnic wear|traditional wear)\b|ঈদ|উৎসব|এথনিক/, "Festive and Ethnic"]
  ];
  for (const [pattern, categoryName] of priorityRules) {
    if (!pattern.test(titleEvidence)) continue;
    const exact = categories.find(c => normCategory(c.name) === normCategory(categoryName));
    if (exact) { cat = exact; break; }
  }

  // Reliable keyword fallback: AI occasionally returns an empty or non-matching category label.
  if (!cat) {
    const evidence = normCategory([
      name, description, p.name, p.name_bn, p.product_type, p.description_en, p.description_bn,
      ...(Array.isArray(p.features_en) ? p.features_en : []),
      ...(Array.isArray(p.features_bn) ? p.features_bn : [])
    ].filter(Boolean).join(" "));
    const rules: Array<[RegExp, string[]]> = [
      [/\b(grinder|blender|kettle|cookware|flask|bottle|kitchen|cooker|toaster|chopper|spice|pressure cooker|rice cooker)\b|রান্নাঘর|গ্রাইন্ডার|ব্লেন্ডার|কেটলি|ফ্লাস্ক|কুকার|মসলা/, ["Kitchen and Dining"]],
      [/\b(earbud|earbuds|earphone|earphones|headphone|headphones|speaker|headset|neckband|bluetooth audio|wireless audio|tws)\b|হেডফোন|ইয়ারফোন|স্পিকার/, ["Audio and Headphones"]],
      [/\b(phone case|charger|cable|power bank|mobile holder|screen protector)\b|চার্জার|কেবল|পাওয়ার ব্যাংক|মোবাইল/, ["Mobile Accessories"]],
      [/\b(smart watch|smart band|fitness tracker|smart gadget)\b|স্মার্ট ওয়াচ|স্মার্ট ব্যান্ড/, ["Smart Gadgets"]],
      [/\b(watch|wristwatch|jewellery|jewelry|necklace|ring|bracelet)\b|ঘড়ি|জুয়েলারি|নেকলেস|আংটি/, ["Watches and Jewellery"]],
      [/\b(shoe|sandal|sneaker|slipper)\b|জুতা|স্যান্ডেল|স্লিপার/, ["Shoes and Sandals"]],
      [/\b(perfume|body spray|deodorant|attar)\b|পারফিউম|বডি স্প্রে|আতর/, ["Perfumes and Body Spray"]],
      [/\b(shampoo|hair oil|hair serum|conditioner)\b|শ্যাম্পু|হেয়ার অয়েল|চুলের তেল/, ["Hair Care"]],
      [/\b(face wash|moisturizer|sunscreen|serum|skin care|cream)\b|ফেসওয়াশ|ময়েশ্চারাইজার|সানস্ক্রিন|স্কিন কেয়ার/, ["Skin Care"]],
      [/\b(bag|backpack|luggage|wallet)\b|ব্যাগ|লাগেজ|ওয়ালেট/, ["Bags and Luggage"]],
      [/\b(baby|diaper|feeding bottle)\b|বেবি|ডায়াপার|শিশু/, ["Baby Care"]],
      [/\b(book|notebook|stationery|pen|pencil)\b|বই|খাতা|কলম|স্টেশনারি/, ["Books and Stationery"]],
      [/\b(sofa|curtain|wall decor|lamp|home decor)\b|ঘর সাজানো|পর্দা|ল্যাম্প|হোম ডেকর/, ["Home Decor"]],
      [/\b(grocery|organic|honey|rice|oil|dates|food)\b|মধু|চাল|খাবার|গ্রোসারি/, ["Grocery and Organic"]],
      [/\b(men.?s|menswear|men clothing|shirt|t shirt|panjabi)\b|পুরুষদের পোশাক|পাঞ্জাবি/, ["Mens Fashion"]],
      [/\b(women.?s|womenswear|women clothing|saree|dress|kurti)\b|নারীদের পোশাক|শাড়ি|থ্রি পিস/, ["Womens Fashion"]],
      [/\b(sports|fitness|gym|yoga)\b|ব্যায়াম|ফিটনেস|জিম/, ["Sports and Fitness"]],
      [/\b(travel|camping|outdoor)\b|ভ্রমণ|ক্যাম্পিং|আউটডোর/, ["Travel and Outdoor"]]
    ];
    for (const [pattern, names] of rules) {
      if (!pattern.test(evidence)) continue;
      cat = categories.find(c => names.some(n => normCategory(c.name) === normCategory(n)));
      if (cat) break;
    }
  }
  const allowedSizes = new Set(["S","M","L","XL","XXL","30","31","32","33","34","35","36"]);
  return {
    ai_provider: providerUsed,
    name: clean(p.name, 200) || name, name_bn: clean(p.name_bn, 200),
    description_en: clean(p.description_en, 3000), description_bn: clean(p.description_bn, 3000),
    features_en: arr(p.features_en).slice(0,6), features_bn: arr(p.features_bn).slice(0,6),
    nutrition_bn: arr(p.nutrition_bn), benefits_bn: arr(p.benefits_bn), how_to_eat_bn: arr(p.how_to_eat_bn), cautions_bn: arr(p.cautions_bn),
    nutrition_en: arr(p.nutrition_en), benefits_en: arr(p.benefits_en), how_to_eat_en: arr(p.how_to_eat_en), cautions_en: arr(p.cautions_en),
    is_food: p.is_food === true, category_id: cat?.id || null, category_name: cat?.name || "",
    product_type: clean(p.product_type, 100), brand_name: clean(p.brand_name, 100),
    attributes: { ...(p.attributes && typeof p.attributes === "object" && !Array.isArray(p.attributes) ? p.attributes : {}), ...(clean(p.brand_name, 100) ? { Brand: clean(p.brand_name, 100) } : {}) },
    sizes: Array.isArray(p.sizes) ? p.sizes.map((x: any) => String(x).toUpperCase()).filter((x: string) => allowedSizes.has(x)) : []
  };
}

async function analyzeStoredImage(path: string, name: string, categories: any[]) {
  const { data, error } = await db.storage.from("product-images").download(path);
  if (error || !data) throw new Error("Storage থেকে AI ছবিটি পাওয়া যায়নি: " + (error?.message || path));
  const bytes = new Uint8Array(await data.arrayBuffer());
  if (bytes.length > 5 * 1024 * 1024) throw new Error("AI ছবির আকার ৫ MB-এর বেশি।");
  const mime = data.type || "image/jpeg";
  if (!/^image\/(jpeg|png|webp|heic|heif)$/i.test(mime)) throw new Error("ছবির ফরম্যাট সমর্থিত নয়।");
  return await analyze(name, categories, { mime, data: b64(bytes) });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const workerToken = req.headers.get("x-worker-token") || "";
    const { data: allowed, error: authError } = await db.rpc("hatbazar_verify_ai_worker_token", { candidate_token: workerToken });
    if (authError || allowed !== true) return json({ error: "Worker authorization failed" }, 401);

    const staleBefore = new Date(Date.now() - 4 * 60 * 1000).toISOString();
    const { data: stale } = await db.from("hatbazar_ai_jobs").select("id").eq("status", "processing").lt("started_at", staleBefore).order("started_at", { ascending: true }).limit(1).maybeSingle();
    if (stale) {
      await db.from("hatbazar_ai_jobs").update({ status: "queued", progress: 0, started_at: null, updated_at: new Date().toISOString() }).eq("id", stale.id).eq("status", "processing");
    }
    const { data: queued, error: queueError } = await db.from("hatbazar_ai_jobs").select("*").eq("status", "queued").order("created_at", { ascending: true }).limit(1).maybeSingle();
    if (queueError) throw queueError;
    if (!queued) return json({ ok: true, message: "No queued jobs" });
    const { data: job, error: claimError } = await db.from("hatbazar_ai_jobs").update({ status: "processing", started_at: new Date().toISOString(), attempts: (queued.attempts || 0) + 1, updated_at: new Date().toISOString() }).eq("id", queued.id).eq("status", "queued").select("*").maybeSingle();
    if (claimError) throw claimError;
    if (!job) return json({ ok: true, message: "Job already claimed" });

    try {
      const payload = job.payload || {};
      const categories = Array.isArray(payload.categories) ? payload.categories.slice(0, 60) : [];
      let result: any;
      if (job.job_type === "bulk") {
        const items = Array.isArray(payload.items) ? payload.items.slice(0, 20) : [];
        const results: any[] = Array.isArray(job.result?.results) ? job.result.results : [];
        const firstPending = results.length;
        const stopAt = Math.min(items.length, firstPending + 2);
        for (let i = firstPending; i < stopAt; i++) {
          const item = items[i];
          const one = await analyzeStoredImage(clean(item.storage_path, 500), clean(item.product_name, 200), categories);
          results.push({ row_index: Number(item.row_index) || i, storage_path: clean(item.storage_path, 500), result: one });
          await db.from("hatbazar_ai_jobs").update({ progress: Math.round((results.length / Math.max(items.length, 1)) * 95), result: { results }, updated_at: new Date().toISOString() }).eq("id", job.id);
        }
        if (results.length < items.length) {
          await db.from("hatbazar_ai_jobs").update({ status: "queued", progress: Math.round((results.length / Math.max(items.length, 1)) * 95), result: { results }, started_at: null, updated_at: new Date().toISOString() }).eq("id", job.id);
          return json({ ok: true, job_id: job.id, status: "queued", progress: Math.round((results.length / Math.max(items.length, 1)) * 95) });
        }
        result = { results };
      } else if (job.job_type === "image") {
        result = { ...(await analyzeStoredImage(clean(payload.storage_path, 500), clean(payload.product_name, 200), categories)), storage_path: clean(payload.storage_path, 500) };
      } else {
        result = await analyze(clean(payload.product_name, 200), categories, undefined, clean(payload.description, 5000));
      }
      const { error: doneError } = await db.from("hatbazar_ai_jobs").update({ status: "completed", progress: 100, result, error: null, completed_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", job.id);
      if (doneError) throw doneError;
      return json({ ok: true, job_id: job.id, status: "completed" });
    } catch (err) {
      const message = err instanceof Error ? err.message : "AI job failed";
      if ((message.includes("Google Gemini সার্ভার") || message.includes("Signal timed out") || message.includes("timed out")) && (job.attempts || 0) < 5) {
        await db.from("hatbazar_ai_jobs").update({
          status: "queued", progress: 0, error: "Gemini সার্ভার ব্যস্ত। স্বয়ংক্রিয়ভাবে আবার চেষ্টা হবে।",
          started_at: null, created_at: new Date().toISOString(), updated_at: new Date().toISOString()
        }).eq("id", job.id);
        return json({ ok: true, job_id: job.id, status: "queued", retry: true });
      }
      await db.from("hatbazar_ai_jobs").update({ status: "failed", error: message.slice(0, 1000), completed_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", job.id);
      return json({ ok: false, job_id: job.id, error: message }, 500);
    }
  } catch (err) {
    return json({ error: err instanceof Error ? err.message : "Worker failed" }, 500);
  }
});
