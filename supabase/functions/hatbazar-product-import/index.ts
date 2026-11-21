import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const BUCKET = "product-images";
const MAX_HTML = 2_500_000;
const MAX_IMAGE = 5 * 1024 * 1024;
const MAX_IMAGES = 10;
const cors = {
  "Access-Control-Allow-Origin": "https://mahatbazar.github.io",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

function reply(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
function clean(value: unknown, max = 5000): string {
  return typeof value === "string" ? value.replace(/\u0000/g, "").trim().slice(0, max) : "";
}
function decodeEntities(value: string): string {
  return value
    .replace(/&amp;/gi, "&").replace(/&quot;/gi, '"').replace(/&#39;|&apos;/gi, "'")
    .replace(/&lt;/gi, "<").replace(/&gt;/gi, ">").replace(/&nbsp;/gi, " ")
    .replace(/&#(\d+);/g, (_m, n) => String.fromCodePoint(Math.min(0x10ffff, Number(n))))
    .replace(/&#x([0-9a-f]+);/gi, (_m, n) => String.fromCodePoint(Math.min(0x10ffff, parseInt(n, 16))));
}
function isPrivateIPv4(ip: string): boolean {
  const p = ip.split(".").map(Number);
  if (p.length !== 4 || p.some(x => !Number.isInteger(x) || x < 0 || x > 255)) return true;
  return p[0] === 0 || p[0] === 10 || p[0] === 127 || p[0] >= 224 ||
    (p[0] === 169 && p[1] === 254) || (p[0] === 172 && p[1] >= 16 && p[1] <= 31) ||
    (p[0] === 192 && p[1] === 168) || (p[0] === 100 && p[1] >= 64 && p[1] <= 127) ||
    (p[0] === 192 && p[1] === 0) || (p[0] === 198 && (p[1] === 18 || p[1] === 19));
}
function isPrivateIPv6(ip: string): boolean {
  const x = ip.toLowerCase();
  return x === "::" || x === "::1" || x.startsWith("fc") || x.startsWith("fd") ||
    /^fe[89ab]/.test(x) || x.startsWith("ff") || x.startsWith("::ffff:127.") ||
    x.startsWith("::ffff:10.") || x.startsWith("::ffff:192.168.");
}
async function assertPublicUrl(raw: string): Promise<URL> {
  let u: URL;
  try { u = new URL(raw); } catch { throw new Error("লিংকটি সঠিক URL নয়।"); }
  if (u.protocol !== "https:" && u.protocol !== "http:") throw new Error("শুধু HTTP/HTTPS পণ্যের লিংক গ্রহণযোগ্য।");
  if (u.username || u.password) throw new Error("লিংকের মধ্যে login credentials দেওয়া যাবে না।");
  const host = u.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (!host || host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") ||
      host.endsWith(".internal") || host === "metadata.google.internal") {
    throw new Error("এই ধরনের private/internal address গ্রহণযোগ্য নয়।");
  }
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(host)) {
    if (isPrivateIPv4(host)) throw new Error("Private network address গ্রহণযোগ্য নয়।");
  } else if (host.includes(":")) {
    if (isPrivateIPv6(host)) throw new Error("Private network address গ্রহণযোগ্য নয়।");
  } else {
    try {
      const records = await Deno.resolveDns(host, "A");
      if (!records.length || records.some(isPrivateIPv4)) throw new Error("Private DNS address blocked.");
      const v6 = await Deno.resolveDns(host, "AAAA").catch(() => []);
      if (v6.some(isPrivateIPv6)) throw new Error("Private DNS address blocked.");
    } catch (_e) {
      throw new Error("এই ডোমেইনের public DNS যাচাই করা যায়নি, তাই নিরাপত্তার জন্য লিংকটি আনা হয়নি।");
    }
  }
  u.hash = "";
  return u;
}
async function safeFetch(raw: string, accept: string, maxBytes: number): Promise<{ response: Response; url: URL; bytes: Uint8Array }> {
  let current = raw;
  for (let hop = 0; hop <= 4; hop++) {
    const url = await assertPublicUrl(current);
    const response = await fetch(url.toString(), {
      method: "GET",
      redirect: "manual",
      headers: { "User-Agent": "HatbazarProductImporter/1.0", "Accept": accept },
      signal: AbortSignal.timeout(18000),
    });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      if (!location || hop === 4) throw new Error("পণ্যের লিংকে অতিরিক্ত redirect পাওয়া গেছে।");
      current = new URL(location, url).toString();
      continue;
    }
    if (!response.ok) throw new Error("পণ্যের পেজ খোলা যায়নি (HTTP " + response.status + ")। Login বা site restriction থাকতে পারে।");
    const type = (response.headers.get("content-type") || "").toLowerCase();
    if (!type.includes(accept.split(",")[0].split(";")[0]) && !type.includes("application/octet-stream")) {
      if (accept.includes("text/html") && !type.includes("text/html") && !type.includes("application/xhtml")) {
        throw new Error("লিংকটি HTML product page নয়।");
      }
    }
    const declared = Number(response.headers.get("content-length") || 0);
    if (declared > maxBytes) throw new Error("পণ্যের পেজ/ছবি নির্ধারিত সাইজের চেয়ে বড়।");
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength > maxBytes) throw new Error("পণ্যের পেজ/ছবি নির্ধারিত সাইজের চেয়ে বড়।");
    return { response, url, bytes };
  }
  throw new Error("পণ্যের পেজ redirect সম্পন্ন হয়নি।");
}
function attrs(tag: string): Record<string, string> {
  const out: Record<string, string> = {};
  const re = /([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(tag))) out[m[1].toLowerCase()] = decodeEntities(m[2] ?? m[3] ?? m[4] ?? "");
  return out;
}
function walkProducts(value: any, out: any[] = []): any[] {
  if (!value) return out;
  if (Array.isArray(value)) { for (const item of value) walkProducts(item, out); return out; }
  if (typeof value !== "object") return out;
  const type = value["@type"];
  const types = Array.isArray(type) ? type : [type];
  if (types.some((t: any) => String(t).toLowerCase() === "product")) out.push(value);
  if (value["@graph"]) walkProducts(value["@graph"], out);
  if (value.itemListElement) walkProducts(value.itemListElement, out);
  return out;
}
function toImageList(value: any, base: URL): string[] {
  const values = Array.isArray(value) ? value : [value];
  const out: string[] = [];
  for (const item of values) {
    const raw = typeof item === "string" ? item : item?.url || item?.contentUrl;
    if (!raw || typeof raw !== "string") continue;
    try {
      const u = new URL(raw, base);
      if (u.protocol === "http:") u.protocol = "https:";
      if (u.protocol === "https:" && !out.includes(u.toString())) out.push(u.toString());
    } catch { /* skip malformed image */ }
  }
  return out;
}
function htmlText(raw: string): string {
  // Decode escaped HTML first, then remove tags so descriptions containing &lt;p&gt; render as plain text.
  const decoded = decodeEntities(raw);
  const text = decoded
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<(script|style|noscript|svg|nav|header|footer|aside|form|button)\b[\s\S]*?<\/\1>/gi, " ")
    .replace(/<(br|hr)\b[^>]*>/gi, "\n")
    .replace(/<\/(p|div|section|article|li|h[1-6]|tr|td|th|dt|dd)>/gi, "\n")
    .replace(/<[^>]+>/g, " ");
  return decodeEntities(text).replace(/[\t ]+/g, " ").replace(/ *\n */g, "\n").replace(/\n{3,}/g, "\n\n").trim().slice(0, 10000);
}
function extractVisibleProductText(html: string): string {
  const main = html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i)?.[1];
  const article = html.match(/<article\b[^>]*>([\s\S]*?)<\/article>/i)?.[1];
  const body = html.match(/<body\b[^>]*>([\s\S]*?)<\/body>/i)?.[1];
  const candidates = [main, article, body, html].filter((x): x is string => !!x).map(htmlText).filter(x => x.length > 80);
  if (!candidates.length) return "";
  const focused = candidates[0];
  const fuller = candidates.sort((a, b) => b.length - a.length)[0];
  return (focused.length >= 250 ? focused : fuller).slice(0, 9000);
}
function stripSourceBranding(value: string, sourceUrl: URL): string {
  let text = String(value || "")
    .replace(/https?:\/\/[^\s<>"']+/gi, " ")
    .replace(/\bwww\.[a-z0-9.-]+\.[a-z]{2,}\b/gi, " ")
    .replace(/\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|net|org|bd|co|shop|store)(?:\.[a-z]{2,})?\b/gi, " ");
  const host = sourceUrl.hostname.toLowerCase().replace(/^www\./, "");
  const root = host.split(".")[0] || "";
  const tokens = new Set<string>([host, root]);
  if (root.includes("bazar")) {
    const prefix = root.replace(/bazar.*/, "");
    tokens.add((prefix + " bazar").trim());
    tokens.add((prefix + "-bazar").trim());
    tokens.add((prefix + ".bazar").trim());
  }
  if (root.endsWith("bd") && root.length > 4) {
    const stem = root.slice(0, -2);
    tokens.add(stem + " bd");
  }
  for (const token of [...tokens].filter(x => x.length >= 3).sort((a,b)=>b.length-a.length)) {
    const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp("(^|[^\\p{L}\\p{N}])" + escaped + "([^\\p{L}\\p{N}]|$)", "giu");
    text = text.replace(re, " ");
  }
  text = text
    .split(/\n+/)
    .filter(line => !/(?:visit|follow|like|subscribe|order|buy|shop|check)\s+(?:us|our|the)?\s*(?:website|page|store|site)|(?:our|official)\s+(?:website|page|store)|ধন্যবাদ.*(?:ভিজিট|অর্ডার)|আরও.*(?:ওয়েবসাইট|ওয়েবসাইট)/i.test(line))
    .join("\n");
  return text.replace(/[ \t]{2,}/g, " ").replace(/ *\n */g, "\n").replace(/\n{3,}/g, "\n\n").trim();
}

function cleanProductName(value: string): string {
  let name = decodeEntities(String(value || "")).replace(/<[^>]+>/g, " ").replace(/\\s+/g, " ").trim();
  // Product titles commonly append the supplier's page title after a pipe.
  // Keep the actual product-name portion, never the marketplace slogan.
  name = name.split(/\\s*\\|\\s*/)[0].trim();
  name = name
    .replace(/\\s+(?:\\||-)\\s*(?:products?|product details?|online (?:marketplace|shopping)|a big online market place|marketplace|reseller platform).*$/i, "")
    .replace(/\\s+/g, " ")
    .replace(/[|\\s,:;-]+$/g, "")
    .trim();
  return name.slice(0, 200);
}

function extract(html: string, pageUrl: URL) {
  const meta: Record<string, string> = {};
  const images: string[] = [];
  const jsonProducts: any[] = [];
  for (const tag of html.match(/<meta\b[^>]*>/gi) || []) {
    const a = attrs(tag);
    const key = (a.property || a.name || a.itemprop || "").toLowerCase();
    const val = a.content || a.value || "";
    if (key && val && !meta[key]) meta[key] = val;
  }
  const titleTag = html.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i);
  const title = decodeEntities((titleTag?.[1] || "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ")).trim();
  for (const script of html.match(/<script\b[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>[\s\S]*?<\/script>/gi) || []) {
    const raw = script.replace(/^<script\b[^>]*>/i, "").replace(/<\/script>$/i, "").trim();
    try { walkProducts(JSON.parse(raw), jsonProducts); } catch { /* ignore invalid JSON-LD */ }
  }
  const product = jsonProducts[0] || {};
  const name = cleanProductName(stripSourceBranding(product.name || meta["og:title"] || meta["twitter:title"] || title, pageUrl));
  const structuredDescriptionRaw = clean(product.description || meta["og:description"] || meta["description"] || meta["twitter:description"], 7000);
  const structuredDescription = htmlText(structuredDescriptionRaw);
  const visibleDetails = extractVisibleProductText(html);
  const description = clean(stripSourceBranding(
    visibleDetails && !visibleDetails.toLowerCase().includes(structuredDescription.toLowerCase())
      ? [structuredDescription, visibleDetails].filter(Boolean).join("\n\n")
      : (visibleDetails || structuredDescription),
    pageUrl
  ), 9000);
  let price = "";
  let originalPrice = "";
  let currency = "";
  const offers = Array.isArray(product.offers) ? product.offers[0] : product.offers;
  const offerPrice = offers && typeof offers === "object" ? (offers.price || offers.lowPrice) : undefined;
  if (offerPrice !== undefined && Number.isFinite(Number(offerPrice))) price = String(offerPrice);
  currency = clean(offers?.priceCurrency, 12);
  if (!price) {
    const metaPrice = meta["product:price:amount"] || meta["og:price:amount"] || meta["price"];
    if (metaPrice && Number.isFinite(Number(metaPrice))) price = String(metaPrice);
  }
  if (!currency) currency = clean(meta["product:price:currency"] || meta["og:price:currency"], 12);

  const parseMoney = (raw: unknown): number => {
    const digits = String(raw ?? "").replace(/[০-৯]/g, d => String("০১২৩৪৫৬৭৮৯".indexOf(d)));
    const cleaned = digits.replace(/[^0-9.]/g, "");
    const value = Number(cleaned);
    return Number.isFinite(value) && value > 0 ? value : 0;
  };
  // Fallback for storefronts that render prices as visible text rather than JSON-LD/meta tags.
  // Only accept amounts explicitly marked with a Bangladeshi currency symbol/code.
  // Search both focused product text and full page text. This supports adjacent labels such as
  // "BDT 290.00BDT 360.00", including currency values separated only by HTML tags/entities.
  // htmlText() intentionally strips script/style content and truncates long pages.
  // Price data can live near the end of the source or inside embedded storefront JSON,
  // so scan decoded raw HTML as well as the visible product text.
  const visiblePriceText = [visibleDetails, decodeEntities(html), htmlText(html)].filter(Boolean).join(" ");
  const markedPrices: number[] = [];
  const addMarkedPrice = (raw: string) => {
    const value = parseMoney(raw);
    if (value > 0 && !markedPrices.includes(value)) markedPrices.push(value);
  };
  const pricePatterns = [
    /(?:৳|Tk\.?|BDT)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)/gi,
    /([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(?:৳|Tk\.?|BDT)/gi
  ];
  for (const pattern of pricePatterns) {
    for (const match of visiblePriceText.matchAll(pattern)) addMarkedPrice(match[1]);
  }
  if (!price && markedPrices.length) {
    price = String(markedPrices[0]);
    currency = currency || "BDT";
  }

  const originalCandidates: number[] = [];
  const addOriginal = (raw: unknown) => {
    const value = parseMoney(raw);
    if (value > 0 && !originalCandidates.includes(value)) originalCandidates.push(value);
  };
  for (const key of [
    "product:original_price:amount", "product:price:original", "product:price:regular_amount",
    "product:price:compare_at", "product:price:compare_at_amount", "og:price:standard_amount",
    "product:price:msrp", "product:price:list"
  ]) addOriginal(meta[key]);

  const offerList = Array.isArray(product.offers) ? product.offers : (product.offers ? [product.offers] : []);
  for (const offer of offerList) {
    const specs = Array.isArray(offer?.priceSpecification) ? offer.priceSpecification : (offer?.priceSpecification ? [offer.priceSpecification] : []);
    for (const spec of specs) {
      const type = String(spec?.priceType || spec?.name || "").toLowerCase();
      if (/(list|regular|original|msrp|strike|compare|retail)/.test(type)) addOriginal(spec?.price);
    }
  }

  // Most storefronts mark the crossed-out price with <del>/<s>, or a class such as
  // old-price, regular-price, compare-at-price, list-price or MRP.
  const addStruckText = (raw: string) => {
    const text = htmlText(raw).replace(/[০-৯]/g, d => String("০১২৩৪৫৬৭৮৯".indexOf(d)));
    for (const match of text.matchAll(/(?:৳|Tk\.?|BDT\s*)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)/gi)) addOriginal(match[1]);
  };
  for (const match of html.matchAll(/<(del|s|strike)\b[^>]*>([\s\S]*?)<\/\1>/gi)) addStruckText(match[2]);
  for (const match of html.matchAll(/<(?:span|div|p|ins)\b([^>]*)>([\s\S]*?)<\/(?:span|div|p|ins)>/gi)) {
    const attrsText = match[1].toLowerCase();
    if (/(?:old[-_ ]?price|regular[-_ ]?price|original[-_ ]?price|compare[-_ ]?at|list[-_ ]?price|mrp|was[-_ ]?price|price[-_ ]?before)/i.test(attrsText)) addStruckText(match[2]);
  }
  for (const match of html.matchAll(/(?:compare_at_price|original_price|old_price|regular_price|list_price|mrp)\s*[=:]\s*["']?([0-9][0-9,]*(?:\.[0-9]{1,2})?)/gi)) addOriginal(match[1]);
  const currentPrice = parseMoney(price);
  // If no explicit crossed-out/list-price metadata was found, use the next
  // currency-marked amount on the product page as the original price.
  if (!originalCandidates.length && markedPrices.length > 1) {
    const pairedOriginal = markedPrices.find(value => value > currentPrice);
    if (pairedOriginal) addOriginal(String(pairedOriginal));
  }
  originalPrice = String(originalCandidates.filter(v => v > currentPrice).sort((a,b)=>b-a)[0] || "");
  const brand = typeof product.brand === "string" ? product.brand : clean(product.brand?.name, 100);
  const sku = clean(product.sku || product.mpn, 100);

  // Only accept images that look like product/gallery assets. Generic OG previews and
  // unlabelled site-wide images are deliberately excluded to avoid importing the shop logo.
  const scored = new Map<string, number>();
  const addCandidate = (raw: unknown, score: number) => {
    for (const url of toImageList(raw, pageUrl)) {
      const lower = url.toLowerCase();
      if (/(?:logo|brandmark|avatar|sprite|placeholder|favicon|payment|badge|icon|banner|spinner)/i.test(lower)) continue;
      const previous = scored.get(url) || 0;
      if (score > previous) scored.set(url, score);
    }
  };
  // Product schema and social metadata can expose primary images and gallery arrays.
  for (const schemaProduct of jsonProducts) addCandidate(schemaProduct.image, 120);
  addCandidate(meta["og:image"], 105);
  addCandidate(meta["og:image:secure_url"], 105);
  addCandidate(meta["twitter:image"], 95);
  addCandidate(meta["twitter:image:src"], 95);
  // Scan image-bearing tags, scoring only tags inside product/gallery-related sections.
  const tagPattern = /<[a-z][^>]*>/gi;
  let tagMatch: RegExpExecArray | null;
  while ((tagMatch = tagPattern.exec(html)) !== null) {
    const tag = tagMatch[0];
    const a = attrs(tag);
    const isImg = /^<img\b/i.test(tag);
    const isAnchor = /^<a\b/i.test(tag);
    const candidates: string[] = [];
    for (const [key, value] of Object.entries(a)) {
      if (!value || !/(?:src|srcset|data-src|data-original|data-lazy|data-image|data-gallery|data-zoom|href)/i.test(key)) continue;
      if (key === "href" && !isAnchor) continue;
      if (key === "href" && !/(?:gallery|zoom|lightbox|product)/i.test((a.class || "") + " " + (a.rel || ""))) continue;
      candidates.push(value);
    }
    const context = (
      html.slice(Math.max(0, tagMatch.index - 2200), tagMatch.index) + " " + tag + " " +
      html.slice(tagMatch.index + tag.length, Math.min(html.length, tagMatch.index + tag.length + 1100))
    ).toLowerCase();
    if (/(?:^|[\\s"'_-])(?:header|footer|navbar|navigation|site-logo|brand-logo|payment|social-icon)(?:[\\s"'_-]|$)/i.test(context)) continue;
    const productContext = /(?:product[-_ ]?(?:gallery|image|photo|detail|media|thumb|slider)|gallery[-_ ]?(?:image|item|thumb|slide|container)|swiper[-_ ]?(?:slide|wrapper|container)|slick[-_ ]?(?:slide|track)|lightbox|zoom[-_ ]?(?:image|gallery)|woocommerce-product-gallery|product-single|pdp[-_ ]?(?:image|gallery)|fotorama|splide__slide|embla__slide)/i.test(context);
    const altText = String(a.alt || a.title || "").toLowerCase();
    const altMatchesProduct = !!altText && name.length > 3 && name.toLowerCase().split(/\\s+/).filter(w=>w.length>3).some(w=>altText.includes(w));
    const classProduct = /(?:product|gallery|zoom|thumbnail|thumb|carousel|slider|fotorama|splide|embla)/i.test((a.class || "") + " " + (a.id || ""));
    const width = Number(a.width || a["data-width"] || 0);
    const height = Number(a.height || a["data-height"] || 0);
    const hasResponsiveImage = !!(a.srcset || a["data-srcset"]);
    const largeImage = width >= 180 || height >= 180;
    const imageUrlLooksProduct = /(?:product|gallery|photo|picture|image|media|uploads?)/i.test(Object.values(a).join(" "));
    const schemaPage = jsonProducts.length > 0;
    const score = productContext ? 100 : (classProduct ? 88 : (altMatchesProduct ? 92 : ((isImg && schemaPage && (largeImage || hasResponsiveImage || imageUrlLooksProduct)) ? 68 : 0)));
    if (!score) continue;
    // Responsive gallery sources may be stored only in srcset attributes.
    for (const key of ["srcset", "data-srcset"]) {
      if (a[key]) {
        for (const item of a[key].split(",")) {
          const candidate = item.trim().split(/\\s+/)[0];
          if (candidate) addCandidate(candidate, score + 2);
        }
      }
    }
    for (const value of candidates) {
      if (value.includes(",")) {
        for (const item of value.split(",")) addCandidate(item.trim().split(/\s+/)[0], score);
      } else addCandidate(value, score);
    }
    const background = (a.style || "").match(/url\([\s"']*(.*?)[\s"']*\)/i)?.[1];
    if (background && productContext) addCandidate(background, score);
    if (!isImg && !isAnchor && !productContext && !classProduct) continue;
  }
  // Embedded JSON and linked bundles are accepted only when their image URL itself
  // carries product/gallery semantics. Generic site assets are never used as fallback.
  for (const script of html.match(/<script\b[\s\S]*?<\/script>/gi) || []) {
    const raw = script.replace(/\\\//g, "/").replace(/\\u002F/gi, "/").replace(/\\u0026/gi, "&");
    for (const candidate of collectImageCandidates(raw, pageUrl)) {
      if (/(?:logo|brandmark|avatar|sprite|placeholder|favicon|payment|badge|icon|banner)/i.test(candidate)) continue;
      if (/(?:product|gallery|photo|picture|image|media|uploads?)/i.test(candidate)) addCandidate(candidate, 70);
    }
  }
  const uniqueImages = [...scored.entries()]
    .filter(([, score]) => score >= 60)
    .sort((a, b) => b[1] - a[1])
    .map(([url]) => url)
    .slice(0, MAX_IMAGES);
  const variants: string[] = [];
  const props = Array.isArray(product.additionalProperty) ? product.additionalProperty : [];
  for (const prop of props) {
    if (prop?.name && prop?.value) variants.push(clean(stripSourceBranding(clean(prop.name, 80) + ": " + clean(prop.value, 120), pageUrl), 200));
  }
  const hasVariant = Array.isArray(product.hasVariant) ? product.hasVariant : product.hasVariant ? [product.hasVariant] : [];
  for (const variant of hasVariant.slice(0, 30)) {
    if (variant?.name) variants.push(clean(stripSourceBranding(variant.name, pageUrl), 160));
    if (variant?.size) variants.push("Size: " + clean(variant.size, 60));
    if (variant?.color) variants.push("Color: " + clean(variant.color, 60));
  }
  return {
    name, description, price, original_price: originalPrice, currency, brand, sku,
    images: uniqueImages,
    variants: [...new Set(variants)].slice(0, 40),
    source_url: pageUrl.toString(),
    source_title: title,
  };
}

function collectImageCandidates(raw: string, base: URL): string[] {
  const out: string[] = [];
  const text = decodeEntities(raw)
    .replaceAll("\\/", "/")
    .replaceAll("\\u002f", "/")
    .replaceAll("\\u002F", "/")
    .replaceAll("\\u0026", "&")
    .replaceAll("\\u003a", ":")
    .replaceAll("\\u003A", ":")
    .replaceAll("\\u003d", "=");
  const add = (value: unknown, key = "") => {
    if (typeof value === "string") {
      if (/(?:image|img|photo|picture|gallery|thumb|thumbnail|zoom|original|media|src|contenturl)/i.test(key)) {
        out.push(...toImageList(value, base));
      }
      return;
    }
    if (Array.isArray(value)) { for (const item of value) add(item, key); return; }
    if (value && typeof value === "object") {
      if (/(?:image|img|photo|picture|gallery|thumb|thumbnail|zoom|original|media|src|contenturl)/i.test(key)) {
        out.push(...toImageList(value, base));
      }
      for (const [k, v] of Object.entries(value as Record<string, unknown>)) add(v, k);
    }
  };
  const parseJson = (candidate: string) => {
    try { add(JSON.parse(candidate)); } catch { /* ignore non-JSON script fragments */ }
  };
  const trimmed = text.trim();
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) parseJson(trimmed);

  // Parse complete framework state payloads instead of truncating them at 200 characters.
  const markers = /__NEXT_DATA__|__NUXT__|__INITIAL_STATE__|__APOLLO_STATE__|application\/json/gi;
  let marker: RegExpExecArray | null;
  let parsedBlocks = 0;
  while ((marker = markers.exec(text)) !== null && parsedBlocks < 12) {
    const searchEnd = Math.min(text.length, marker.index + 1200);
    let start = -1;
    for (let i = marker.index + marker[0].length; i < searchEnd; i++) {
      if (text[i] === "{" || text[i] === "[") { start = i; break; }
    }
    if (start < 0) continue;
    const stack: string[] = [];
    let inString = false;
    let escaped = false;
    let end = -1;
    for (let i = start; i < text.length && i < start + 2_000_000; i++) {
      const ch = text[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') { inString = true; continue; }
      if (ch === "{" || ch === "[") stack.push(ch);
      else if (ch === "}" || ch === "]") {
        const expected = ch === "}" ? "{" : "[";
        if (stack.pop() !== expected) break;
        if (!stack.length) { end = i + 1; break; }
      }
    }
    if (end > start) {
      parseJson(text.slice(start, end));
      parsedBlocks++;
    }
  }

  // Also inspect image URLs embedded in JavaScript/CSS strings.
  const candidates = text.match(/(?:https?:)?\/\/[^"'\\\s<>]+|\/[^"'\\\s<>]+/g) || [];
  for (const candidate of candidates) {
    const cleaned = candidate.replace(/[),;]+$/g, "");
    if (/\.(?:jpe?g|png|webp|gif|avif)(?:[?#]|$)/i.test(cleaned) ||
        /(?:image|img|photo|picture|gallery|product[-_/]?(?:image|photo)|uploads?\/products?\/|\/media\/)/i.test(cleaned)) {
      out.push(...toImageList(cleaned, base));
    }
  }
  return [...new Set(out)];
}
async function collectLinkedAssetText(html: string, pageUrl: URL): Promise<string[]> {
  const urls: string[] = [];
  for (const tag of html.match(/<(?:script|link)\b[^>]*>/gi) || []) {
    const a = attrs(tag);
    const isScript = /^<script\b/i.test(tag);
    const isStylesheet = /^<link\b/i.test(tag) && /stylesheet/i.test(a.rel || "");
    const raw = isScript ? a.src : (isStylesheet ? a.href : "");
    if (!raw) continue;
    try {
      const u = new URL(raw, pageUrl);
      if ((u.protocol === "https:" || u.protocol === "http:") && !urls.includes(u.toString())) urls.push(u.toString());
    } catch { /* skip malformed asset URL */ }
  }
  const results: string[] = [];
  for (const url of urls.slice(0, 8)) {
    try {
      const fetched = await safeFetch(url, "text/javascript,text/css,application/json,text/plain", 1_500_000);
      results.push(new TextDecoder("utf-8").decode(fetched.bytes));
    } catch { /* CDN assets may deny server-side requests */ }
  }
  return results;
}

function extFor(type: string): string {
  if (type.includes("png")) return "png";
  if (type.includes("webp")) return "webp";
  if (type.includes("gif")) return "gif";
  if (type.includes("avif")) return "avif";
  return "jpg";
}
async function uploadImage(userId: string, rawUrl: string, index: number): Promise<string> {
  const fetched = await safeFetch(rawUrl, "image/avif,image/webp,image/png,image/jpeg,image/gif", MAX_IMAGE);
  const type = (fetched.response.headers.get("content-type") || "").split(";")[0].toLowerCase();
  if (!/^image\/(jpeg|png|webp|gif|avif)$/.test(type)) throw new Error("ছবি হিসেবে গ্রহণযোগ্য ফাইল পাওয়া যায়নি।");
  const bytes = fetched.bytes;
  if (bytes.length < 12) throw new Error("ছবির ফাইলটি অসম্পূর্ণ।");
  const path = "imports/" + userId + "/" + crypto.randomUUID() + "-" + (index + 1) + "." + extFor(type);
  const upload = await fetch(SUPABASE_URL + "/storage/v1/object/" + BUCKET + "/" + path.split("/").map(encodeURIComponent).join("/"), {
    method: "POST",
    headers: {
      "Authorization": "Bearer " + SERVICE_KEY,
      "apikey": SERVICE_KEY,
      "Content-Type": type,
      "x-upsert": "true",
    },
    body: bytes,
  });
  if (!upload.ok) {
    const detail = await upload.text().catch(() => "");
    throw new Error("Hatbazar Storage-এ ছবি রাখা যায়নি: " + detail.slice(0, 180));
  }
  return SUPABASE_URL + "/storage/v1/object/public/" + BUCKET + "/" + path.split("/").map(encodeURIComponent).join("/");
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "শুধু POST অনুরোধ গ্রহণযোগ্য।" }, 405);
  try {
    const origin = req.headers.get("origin") || "";
    if (origin && origin !== "https://mahatbazar.github.io") return reply({ error: "এই Origin অনুমোদিত নয়।" }, 403);
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!token || !ANON_KEY) return reply({ error: "Admin login session পাওয়া যায়নি।" }, 401);
    if (!SERVICE_KEY) return reply({ error: "Image Storage-এর server configuration পাওয়া যায়নি।" }, 503);
    const userDb = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: "Bearer " + token } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userDb.auth.getUser(token);
    if (authError || !authData.user) return reply({ error: "Admin login যাচাই করা যায়নি। আবার Login করুন।" }, 401);
    const { data: profile, error: profileError } = await userDb.from("profiles").select("role").eq("id", authData.user.id).maybeSingle();
    if (profileError || !["admin", "sub_admin"].includes(profile?.role || "")) return reply({ error: "শুধু অনুমোদিত Admin এই সুবিধা ব্যবহার করতে পারবেন।" }, 403);
    const body = await req.json().catch(() => ({}));
    const rawUrl = clean(body.url, 2048);
    if (!rawUrl) return reply({ error: "Product URL দেওয়া হয়নি।" }, 400);
    const initial = await assertPublicUrl(rawUrl);
    const fetched = await safeFetch(initial.toString(), "text/html,application/xhtml+xml", MAX_HTML);
    const html = new TextDecoder("utf-8").decode(fetched.bytes);
    const data = extract(html, fetched.url);
    // Inspect linked JS/CSS bundles because some storefronts keep gallery URLs outside HTML.
    const assetTags = html.match(/<(?:script|link)\\b[^>]*>/gi) || [];
    const assetUrls: string[] = [];
    for (const tag of assetTags) {
      const a = attrs(tag);
      const raw = /^<script\\b/i.test(tag) ? a.src : (/^<link\\b/i.test(tag) && /stylesheet/i.test(a.rel || "") ? a.href : "");
      if (!raw) continue;
      try {
        const u = new URL(raw, fetched.url);
        if ((u.protocol === "https:" || u.protocol === "http:") && !assetUrls.includes(u.toString())) assetUrls.push(u.toString());
      } catch { /* skip malformed asset URL */ }
    }
    const linkedAssets = await collectLinkedAssetText(html, fetched.url);
    const assetImageCandidates: string[] = [];
    const apiHints = new Set<string>();
    const endpointPattern = new RegExp("/(?:api|graphql|v[0-9]+)/[A-Za-z0-9_./{}:-]{2,120}", "gi");
    for (const assetText of linkedAssets) {
      for (const candidate of collectImageCandidates(assetText, fetched.url)) {
        if (/(?:product|gallery|photo|picture|image|media|uploads?)/i.test(candidate) &&
            !/(?:logo|brandmark|avatar|sprite|placeholder|favicon|payment|badge|icon|banner)/i.test(candidate)) {
          data.images.push(candidate);
          assetImageCandidates.push(candidate);
        }
      }
      for (const match of assetText.matchAll(endpointPattern)) {
        const hint = match[0].split(/[?#"'\\s]/)[0];
        if (hint && !/\\.(?:js|css|map|png|jpe?g|webp|svg)$/i.test(hint)) apiHints.add(hint.slice(0, 140));
        if (apiHints.size >= 30) break;
      }
    }
    data.images = [...new Set(data.images)].slice(0, MAX_IMAGES);
    console.log("hatbazar-product-import diagnostics", JSON.stringify({
      host: fetched.url.hostname,
      pagePath: fetched.url.pathname,
      htmlBytes: fetched.bytes.byteLength,
      linkedAssetTags: assetUrls.length,
      fetchedAssetBundles: linkedAssets.length,
      assetPaths: assetUrls.slice(0, 8).map(value => new URL(value).pathname),
      apiPathHints: [...apiHints].slice(0, 30),
      bundleImageCandidates: [...new Set(assetImageCandidates)].length,
      totalImageCandidates: data.images.length,
      extractedPrice: data.price || null,
      extractedOriginalPrice: data.original_price || null,
      hasStockText: /(?:in stock|out of stock|only\\s+\\d+|\\d+\\s+items?\\s+left|স্টকে|স্টক|পিস বাকি)/i.test(extractVisibleProductText(html))
    }));
    if (!data.name) return reply({ error: "পণ্যের নাম পাওয়া যায়নি। এই পেজটি login-protected বা JavaScript দিয়ে তৈরি হতে পারে।" }, 422);
    const storedImages: string[] = [];
    const imageErrors: string[] = [];
    for (let i = 0; i < data.images.length; i++) {
      try { storedImages.push(await uploadImage(authData.user.id, data.images[i], i)); }
      catch (e) { imageErrors.push("ছবি " + (i + 1) + ": " + (e instanceof Error ? e.message : "ব্যর্থ")); }
    }
    if (!storedImages.length) return reply({ error: "কোনো ছবিই Hatbazar-এ সংরক্ষণ করা যায়নি। " + imageErrors.join(" | ") }, 502);
    return reply({
      ok: true,
      product: {
        name: data.name,
        name_bn: "",
        description: data.description,
        price: data.price,
        selling_price: data.price,
        original_price: data.original_price,
        supplier_price: data.price,
        currency: data.currency,
        brand: data.brand,
        sku: data.sku,
        variants: data.variants,
        source_url: data.source_url,
        source_title: data.source_title,
        image_urls: storedImages,
        image_count: storedImages.length,
        images_found: data.images.length,
        image_warnings: [...(!data.images.length ? ["এই পেজ থেকে Product Gallery-এর ছবি স্বয়ংক্রিয়ভাবে পাওয়া যায়নি। Product Images অংশে নিজে ছবি যোগ করুন।"] : []), ...imageErrors],
      },
    });
  } catch (error) {
    console.error("hatbazar-product-import failed:", error);
    return reply({ error: error instanceof Error ? error.message : "পণ্য Import করা যায়নি।" }, 400);
  }
});