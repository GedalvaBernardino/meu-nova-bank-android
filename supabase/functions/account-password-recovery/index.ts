const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Vary": "Origin",
};
const headers = {
  ...cors,
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
};
const reply = (payload: unknown, status = 200) =>
  new Response(JSON.stringify(payload), { status, headers });
const generic = () => reply({ status: "recovery_requested" });
const redirectTo = "meunovabank://auth/callback";

async function hmacHex(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value)),
  );
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const contentLength = Number(req.headers.get("content-length") || "0");
  if (contentLength > 4096) return reply({ error: "Invalid request" }, 413);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const rateSecret = Deno.env.get("LOGIN_RATE_LIMIT_SECRET");
  if (!url || !anon || !service || !rateSecret) {
    return reply({ error: "Recovery service unavailable" }, 503);
  }

  let body: { account_number?: unknown };
  try {
    body = await req.json();
  } catch {
    return reply({ error: "Invalid request" }, 400);
  }
  const account = typeof body.account_number === "string"
    ? body.account_number.trim()
    : "";
  // The live account allocator and database constraint currently support 6 digits.
  if (!/^\d{6}$/.test(account)) return reply({ error: "Invalid account format" }, 400);

  const ip = (
    req.headers.get("cf-connecting-ip") ||
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    "unknown"
  ).slice(0, 80);
  const adminHeaders = {
    apikey: service,
    Authorization: `Bearer ${service}`,
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  };
  const rpc = (name: string, payload: unknown) =>
    fetch(`${url}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: adminHeaders,
      body: JSON.stringify(payload),
    });

  try {
    // Separate account and IP buckets; values stored in the existing limiter are HMACs only.
    const accountHash = await hmacHex(rateSecret, `password-recovery-account|${account}`);
    const ipHash = await hmacHex(rateSecret, `password-recovery-ip|${ip}`);
    const [accountGate, ipGate] = await Promise.all([
      rpc("meunova_login_rate_limit", { p_key_hash: accountHash, p_success: false }),
      rpc("meunova_login_rate_limit", { p_key_hash: ipHash, p_success: false }),
    ]);
    if (!accountGate.ok || !ipGate.ok) {
      return reply({ error: "Recovery service unavailable" }, 503);
    }
    const accountAllowed = await accountGate.json();
    const ipAllowed = await ipGate.json();
    if (accountAllowed !== true || ipAllowed !== true) {
      await pause(300);
      return generic();
    }

    const lookup = await rpc("meunova_login_email", { p_account_number: account });
    if (!lookup.ok) return reply({ error: "Recovery service unavailable" }, 503);
    const email = await lookup.json();

    // Always return the same message. Never reveal whether the account exists.
    if (typeof email === "string" && email.includes("@")) {
      const recoverUrl = new URL(`${url}/auth/v1/recover`);
      recoverUrl.searchParams.set("redirect_to", redirectTo);
      const sent = await fetch(recoverUrl, {
        method: "POST",
        headers: {
          apikey: anon,
          Authorization: `Bearer ${anon}`,
          "Content-Type": "application/json",
          "Cache-Control": "no-store",
        },
        body: JSON.stringify({ email }),
      });
      if (!sent.ok) console.warn("Auth recovery email request failed", sent.status);
    }
    await pause(300);
    return generic();
  } catch {
    return reply({ error: "Recovery service unavailable" }, 503);
  }
});
