import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") || "";
const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
const cors = {"Access-Control-Allow-Origin":"https://mahatbazar.github.io","Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
function reply(data: unknown,status=200){return new Response(JSON.stringify(data),{status,headers:{...cors,"Content-Type":"application/json"}});}
function cleanText(value:unknown,max=5000){return typeof value==="string"?value.trim().slice(0,max):"";}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return reply({error:"শুধু POST অনুরোধ গ্রহণযোগ্য।"},405);
 try{
  const token=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  if(!token)return reply({error:"Admin login session পাওয়া যায়নি।"},401);
  const {data:authData,error:authError}=await db.auth.getUser(token);
  if(authError||!authData.user)return reply({error:"Admin login যাচাই করা যায়নি। আবার Login করুন।"},401);
  const {data:profile,error:profileError}=await db.from("profiles").select("role").eq("id",authData.user.id).maybeSingle();
  if(profileError||profile?.role!=="admin")return reply({error:"শুধু Admin এই সুবিধা ব্যবহার করতে পারবেন।"},403);
  if(!GEMINI_API_KEY)return reply({error:"AI চালু করতে Supabase Edge Function Secret-এ GEMINI_API_KEY যোগ করতে হবে।"},503);
  const body=await req.json();
  const mimeType=cleanText(body.mime_type,80),imageBase64=cleanText(body.image_base64,8000000);
  if(!/^image\/(jpeg|png|webp|heic|heif)$/i.test(mimeType))return reply({error:"JPG, PNG বা WebP ছবি ব্যবহার করুন।"},400);
  if(!imageBase64||imageBase64.length>7000000)return reply({error:"ছবিটি খালি অথবা খুব বড়। ৫ MB-এর মধ্যে ছবি দিন।"},400);
  const categories=Array.isArray(body.categories)?body.categories.slice(0,60).map((c:any)=>({name:cleanText(c?.name,100),name_bn:cleanText(c?.name_bn,100)})):[];
  const categoryList=categories.map((c:any)=>c.name_bn+" / "+c.name).join("\n");
  const prompt="You are Hatbazar Bangladesh marketplace's expert ecommerce catalog writer. Inspect the product photo and return ONLY valid JSON.\n"+
   "Write persuasive, polished, trustworthy product copy in natural Bangladeshi Bengali and clear retail English. Make descriptions specific to what is visibly supported. Never invent brand, model, material, dimensions, warranty, certification, technical specification, health benefit, compatibility, origin, or accessories. Omit uncertain facts.\n"+
   "Choose exactly one best matching category from this database list, or empty category_name if none fits:\n"+categoryList+"\n"+
   '{"name":"English title","name_bn":"Bengali title","description_en":"attractive 2-4 sentence description","description_bn":"attractive 2-4 sentence Bengali description","features_en":["3-6 evidence-based features"],"features_bn":["same features in Bengali"],"category_name":"exact English category or empty","product_type":"short type","attributes":{"Color":"only if clear","Material":"only if certain","Brand":"only if legible","Model":"only if legible"},"sizes":["applicable sizes"]}.\n'+
   'Size rules: apparel gets ["S","M","L","XL","XXL"]; add ["30","31","32","33","34","35","36"] only for garment types where numeric sizing is genuinely relevant, such as waist trousers. Footwear may use 30-36 only if appropriate. Phones, electronics, home goods and accessories must have sizes []. These are size options, not stock promises. Never invent prices or stock.';
  const apiResponse=await fetch("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key="+encodeURIComponent(GEMINI_API_KEY),{
   method:"POST",headers:{"Content-Type":"application/json"},
   body:JSON.stringify({contents:[{parts:[{text:prompt},{inline_data:{mime_type:mimeType,data:imageBase64}}]}],generationConfig:{temperature:0.35,responseMimeType:"application/json"}})
  });
  const aiResult=await apiResponse.json();
  if(!apiResponse.ok)return reply({error:cleanText(aiResult?.error?.message,400)||"AI থেকে তথ্য তৈরি করা যায়নি।"},502);
  const raw=aiResult?.candidates?.[0]?.content?.parts?.map((p:any)=>p.text||"").join("")||"";
  let parsed:any;try{parsed=JSON.parse(raw);}catch{return reply({error:"AI-এর উত্তর সঠিকভাবে পড়া যায়নি। আবার চেষ্টা করুন।"},502);}
  const allowed=categories.find((c:any)=>c.name.toLowerCase()===cleanText(parsed.category_name,100).toLowerCase());
  const validSizes=new Set(["S","M","L","XL","XXL","30","31","32","33","34","35","36"]);
  const sizes=Array.isArray(parsed.sizes)?parsed.sizes.map((s:any)=>String(s).toUpperCase()).filter((s:string)=>validSizes.has(s)):[];
  const attributes=parsed.attributes&&typeof parsed.attributes==="object"&&!Array.isArray(parsed.attributes)?parsed.attributes:{};
  const category=allowed?await db.from("categories").select("id").eq("name",allowed.name).maybeSingle():null;
  return reply({name:cleanText(parsed.name,200),name_bn:cleanText(parsed.name_bn,200),description_en:cleanText(parsed.description_en,3000),description_bn:cleanText(parsed.description_bn,3000),
   features_en:Array.isArray(parsed.features_en)?parsed.features_en.map((x:unknown)=>cleanText(x,250)).filter(Boolean).slice(0,6):[],
   features_bn:Array.isArray(parsed.features_bn)?parsed.features_bn.map((x:unknown)=>cleanText(x,250)).filter(Boolean).slice(0,6):[],
   category_id:category?.data?.id||null,category_name:allowed?.name||"",product_type:cleanText(parsed.product_type,100),attributes,sizes});
 }catch(error){return reply({error:error instanceof Error?error.message:"AI অনুরোধ ব্যর্থ হয়েছে।"},500);}
});