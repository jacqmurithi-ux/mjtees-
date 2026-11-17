Deno.serve(async (request: Request) => {
  const allowedOrigins = (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((x) => x.trim()).filter(Boolean);
  const origin = request.headers.get("origin") ?? "";
  const cors = {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    "Vary": "Origin",
  };
  const reply = (body: unknown, status: number) => new Response(JSON.stringify(body), {
    status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
  if (!allowedOrigins.includes(origin)) return new Response("Forbidden", { status: 403 });
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (request.method !== "POST") return reply({ message: "Method not allowed" }, 405);
  if (!(request.headers.get("content-type") ?? "").toLowerCase().includes("application/json")) return reply({ message: "Invalid request" }, 415);
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (declaredLength > 16_384) return reply({ message: "Request too large" }, 413);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const captchaSecret = Deno.env.get("TURNSTILE_SECRET_KEY");
  const rateSalt = Deno.env.get("RATE_LIMIT_SALT");
  if (!supabaseUrl || !serviceKey || !captchaSecret || !rateSalt) return reply({ message: "Enquiry service unavailable" }, 503);

  let body: Record<string, unknown>;
  try {
    const raw = await request.text();
    if (new TextEncoder().encode(raw).length > 16_384) return reply({ message: "Request too large" }, 413);
    body = JSON.parse(raw);
    if (!body || Array.isArray(body) || typeof body !== "object") throw new Error("Invalid object");
  } catch {
    return reply({ message: "Invalid request" }, 400);
  }

  const allowedKeys = new Set([
    "business_slug", "contact_name", "phone", "email", "requested_service", "description",
    "quantity", "desired_by", "customer_supplies_item", "artwork_drive_url", "turnstile_token", "request_id",
  ]);
  if (Object.keys(body).some((key) => !allowedKeys.has(key))) return reply({ message: "Invalid request fields" }, 400);

  const validText = (v: unknown, max: number): v is string =>
    typeof v === "string" && v.trim().length > 0 && v.trim().length <= max;
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const slug = body.business_slug;
  const contactName = body.contact_name;
  const service = body.requested_service;
  const description = body.description;
  const phoneValue = typeof body.phone === "string" ? body.phone.trim() : "";
  const emailValue = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const phone = phoneValue || null;
  const email = emailValue || null;
  const token = body.turnstile_token;
  const requestId = typeof body.request_id === "string" && uuidPattern.test(body.request_id) ? body.request_id : crypto.randomUUID();

  if (!validText(slug, 80) || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug.trim())) return reply({ message: "Invalid enquiry" }, 400);
  if (!validText(contactName, 120) || !validText(service, 160) || !validText(description, 4000)) return reply({ message: "Please check the required fields" }, 400);
  if ((!phone || phone.length < 7 || phone.length > 40) && (!email || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) {
    return reply({ message: "Provide a valid phone number or email address" }, 400);
  }
  if (phone && (phone.length < 7 || phone.length > 40)) return reply({ message: "Invalid phone number" }, 400);
  if (email && (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) return reply({ message: "Invalid email address" }, 400);

  let quantity: number | null = null;
  if (body.quantity !== undefined && body.quantity !== null && body.quantity !== "") {
    quantity = Number(body.quantity);
    if (!Number.isFinite(quantity) || quantity <= 0 || quantity > 100_000) return reply({ message: "Invalid quantity" }, 400);
  }
  let desiredBy: string | null = null;
  if (body.desired_by !== undefined && body.desired_by !== null && body.desired_by !== "") {
    if (typeof body.desired_by !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(body.desired_by)) return reply({ message: "Invalid requested date" }, 400);
    const parsedDate = new Date(body.desired_by + "T00:00:00Z");
    if (Number.isNaN(parsedDate.getTime()) || parsedDate.toISOString().slice(0, 10) !== body.desired_by) {
      return reply({ message: "Invalid requested date" }, 400);
    }
    desiredBy = body.desired_by;
  }
  if (body.customer_supplies_item !== undefined && typeof body.customer_supplies_item !== "boolean") {
    return reply({ message: "Invalid customer-supplied item choice" }, 400);
  }

  let artworkUrl: string | null = null;
  if (body.artwork_drive_url !== undefined && body.artwork_drive_url !== null && body.artwork_drive_url !== "") {
    if (typeof body.artwork_drive_url !== "string" || body.artwork_drive_url.length > 2048) return reply({ message: "Invalid artwork link" }, 400);
    try {
      const parsed = new URL(body.artwork_drive_url);
      if (parsed.protocol !== "https:" || !["drive.google.com", "docs.google.com"].includes(parsed.hostname)) return reply({ message: "Artwork link must be a Google Drive link" }, 400);
      artworkUrl = parsed.toString();
    } catch {
      return reply({ message: "Invalid artwork link" }, 400);
    }
  }
  if (!validText(token, 4096)) return reply({ message: "Complete the verification check" }, 400);

  // Trust only the platform-injected Cloudflare client IP. x-real-ip can be supplied by a direct caller.
  const forwardedIp = request.headers.get("cf-connecting-ip") ?? "";
  const captchaForm = new URLSearchParams({ secret: captchaSecret, response: token });
  if (forwardedIp) captchaForm.set("remoteip", forwardedIp);
  let captcha: { success?: boolean; hostname?: string };
  try {
    const verify = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: captchaForm,
    });
    captcha = await verify.json();
  } catch {
    return reply({ message: "Verification is temporarily unavailable" }, 503);
  }
  if (!captcha.success || !captcha.hostname) return reply({ message: "Verification failed" }, 400);
  const allowedHosts = allowedOrigins.map((value) => { try { return new URL(value).hostname; } catch { return ""; } });
  if (!allowedHosts.includes(captcha.hostname)) return reply({ message: "Verification failed" }, 400);

  async function hmac(value: string): Promise<string> {
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(rateSalt), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const bytes = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
    return Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
  }
  const networkId = forwardedIp || "unknown";
  const contactId = phone ? phone.replace(/[^\d+]/g, "") : (email ?? "");
  const ipHash = await hmac("ip:" + networkId);
  const contactHash = await hmac("contact:" + contactId.toLowerCase());

  const rpcBody = {
    p_business_slug: slug.trim(), p_contact_name: contactName.trim(), p_phone: phone, p_email: email,
    p_requested_service: service.trim(), p_description: description.trim(), p_quantity: quantity,
    p_desired_by: desiredBy, p_customer_supplies_item: body.customer_supplies_item === true,
    p_artwork_drive_url: artworkUrl, p_ip_hash: ipHash, p_contact_hash: contactHash, p_request_id: requestId,
  };
  try {
    const response = await fetch(supabaseUrl.replace(/\/$/, "") + "/rest/v1/rpc/submit_public_enquiry", {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: serviceKey, Authorization: "Bearer " + serviceKey },
      body: JSON.stringify(rpcBody),
    });
    if (!response.ok) {
      if (response.status === 429) return reply({ message: "Please wait before sending another enquiry" }, 429);
      return reply({ message: "We could not receive your enquiry. Please try again later." }, 503);
    }
    const result = await response.json();
    if (result?.rate_limited === true) return reply({ message: "Please wait before sending another enquiry" }, 429);
    if (typeof result?.public_reference !== "string") return reply({ message: "We could not receive your enquiry. Please try again later." }, 503);
    return reply({ ok: true, public_reference: result.public_reference, message: "Enquiry received" }, 201);
  } catch {
    return reply({ message: "We could not receive your enquiry. Please try again later." }, 503);
  }
});
