import crypto from "node:crypto";

const DEFAULT_SUPABASE_URL = "https://ayzmmchrepbtfnjegqxp.supabase.co";
const DEFAULT_PUBLIC_BASE_URL = "https://www.mindrop.chat";
const FEISHU_API_BASE = "https://open.feishu.cn/open-apis";

export default async function handler(request, response) {
  if (request.method !== "POST") {
    response.status(405).json({ error: "Method not allowed" });
    return;
  }

  const config = loadConfig();
  const missing = missingConfigKeys(config);
  if (missing.length > 0) {
    response.status(500).json({ error: "Feishu connector is not configured", missing });
    return;
  }

  let user;
  try {
    user = await authenticateUser(config, request);
  } catch (error) {
    response.status(401).json({ error: safeError(error) || "Unauthorized" });
    return;
  }

  const body = await readJSONBody(request);
  const credentials = normalizeCredentials(body);
  const validationError = validateCredentials(credentials);
  if (validationError) {
    response.status(400).json({ error: validationError });
    return;
  }

  try {
    await validateFeishuCredentials(credentials);
  } catch (error) {
    response.status(400).json({ error: `飞书 App ID 或 App Secret 校验失败：${safeError(error)}` });
    return;
  }

  try {
    const now = new Date();
    const callbackToken = randomToken(24);
    const pairingCode = makePairingCode();
    const pairingExpiresAt = new Date(now.getTime() + 30 * 60 * 1000).toISOString();
    const connection = await createConnection(config, {
      userID: user.id,
      callbackToken,
      pairingCode,
      pairingExpiresAt,
      timeZone: credentials.timeZone,
      appID: credentials.appID,
      appSecret: encryptCredential(credentials.appSecret, config),
      verificationToken: encryptCredential(credentials.verificationToken, config),
      encryptKey: encryptCredential(credentials.encryptKey, config),
      now: now.toISOString(),
    });

    response.status(200).json({
      connectionID: connection.id,
      callbackURL: `${config.publicBaseURL}/api/feishu/events?connection=${encodeURIComponent(callbackToken)}`,
      pairingCode,
      pairingExpiresAt,
    });
  } catch (error) {
    console.error("Mindrop Feishu connection create failed", safeError(error));
    response.status(500).json({ error: "飞书连接创建失败，请稍后再试" });
  }
}

function loadConfig() {
  return {
    supabaseURL: trimTrailingSlash(process.env.SUPABASE_URL || DEFAULT_SUPABASE_URL),
    supabaseServiceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY,
    feishuCredentialsKey: process.env.FEISHU_CREDENTIALS_KEY,
    publicBaseURL: trimTrailingSlash(process.env.MINDROP_PUBLIC_URL || DEFAULT_PUBLIC_BASE_URL),
  };
}

function missingConfigKeys(config) {
  return [["SUPABASE_SERVICE_ROLE_KEY", config.supabaseServiceRoleKey]]
    .filter(([, value]) => !value)
    .map(([key]) => key);
}

async function authenticateUser(config, request) {
  const authorization = headerValue(request.headers, "authorization");
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match?.[1]) {
    throw new Error("Missing authorization");
  }

  const authResponse = await fetch(`${config.supabaseURL}/auth/v1/user`, {
    method: "GET",
    headers: {
      apikey: config.supabaseServiceRoleKey,
      authorization: `Bearer ${match[1]}`,
      "content-type": "application/json",
    },
  });
  const text = await authResponse.text();
  if (!authResponse.ok) {
    throw new Error(safeErrorText(text) || "Invalid session");
  }
  const user = parseJSON(text);
  if (!user?.id) {
    throw new Error("Invalid session");
  }
  return user;
}

async function validateFeishuCredentials(credentials) {
  const feishuResponse = await fetch(`${FEISHU_API_BASE}/auth/v3/tenant_access_token/internal`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      app_id: credentials.appID,
      app_secret: credentials.appSecret,
    }),
  });
  const text = await feishuResponse.text();
  if (!feishuResponse.ok) {
    throw new Error(`${feishuResponse.status} ${safeErrorText(text)}`);
  }
  const payload = parseJSON(text);
  if (payload?.code !== 0 || !payload?.tenant_access_token) {
    throw new Error(`${payload?.code ?? "unknown"} ${safeErrorText(payload?.msg)}`);
  }
}

async function createConnection(config, values) {
  const revokeQuery = new URLSearchParams({
    user_id: `eq.${values.userID}`,
    revoked_at: "is.null",
  });
  await supabaseFetch(config, `/rest/v1/feishu_bot_connections?${revokeQuery}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({
      status: "revoked",
      revoked_at: values.now,
      updated_at: values.now,
    }),
    expectJSON: false,
  });

  const created = await supabaseFetch(config, "/rest/v1/feishu_bot_connections", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({
      user_id: values.userID,
      callback_token: values.callbackToken,
      app_id: values.appID,
      app_secret_encrypted: values.appSecret,
      verification_token_encrypted: values.verificationToken,
      encrypt_key_encrypted: values.encryptKey,
      pairing_code: values.pairingCode,
      pairing_expires_at: values.pairingExpiresAt,
      time_zone: values.timeZone || "Asia/Shanghai",
      status: "configured",
      created_at: values.now,
      updated_at: values.now,
      revoked_at: null,
    }),
  });

  return created?.[0] || {};
}

async function supabaseFetch(config, path, options = {}) {
  const supabaseResponse = await fetch(`${config.supabaseURL}${path}`, {
    method: options.method || "GET",
    headers: {
      apikey: config.supabaseServiceRoleKey,
      authorization: `Bearer ${config.supabaseServiceRoleKey}`,
      "content-type": "application/json",
      ...(options.headers || {}),
    },
    body: options.body,
  });
  const text = await supabaseResponse.text();
  if (!supabaseResponse.ok) {
    throw new Error(`Supabase ${supabaseResponse.status}: ${safeErrorText(text)}`);
  }
  if (options.expectJSON === false || text.length === 0) {
    return null;
  }
  return JSON.parse(text);
}

async function readJSONBody(request) {
  if (typeof request.body === "string") {
    return parseJSON(request.body || "{}") || {};
  }
  if (Buffer.isBuffer(request.body)) {
    return parseJSON(request.body.toString("utf8") || "{}") || {};
  }
  if (request.body && typeof request.body === "object" && !Buffer.isBuffer(request.body)) {
    return request.body;
  }

  const chunks = [];
  for await (const chunk of request) {
    chunks.push(Buffer.from(chunk));
  }
  const text = Buffer.concat(chunks).toString("utf8");
  return parseJSON(text || "{}") || {};
}

function normalizeCredentials(body) {
  return {
    appID: sanitizeText(body?.appID || body?.app_id),
    appSecret: sanitizeText(body?.appSecret || body?.app_secret),
    verificationToken: sanitizeText(body?.verificationToken || body?.verification_token),
    encryptKey: sanitizeText(body?.encryptKey || body?.encrypt_key),
    timeZone: sanitizeText(body?.timeZone || body?.time_zone) || "Asia/Shanghai",
  };
}

function validateCredentials(credentials) {
  if (!credentials.appID) {
    return "缺少 App ID";
  }
  if (!credentials.appSecret) {
    return "缺少 App Secret";
  }
  if (!credentials.verificationToken) {
    return "缺少 Verification Token";
  }
  if (!credentials.encryptKey) {
    return "缺少 Encrypt Key";
  }
  if (credentials.appID.length > 128 || credentials.appSecret.length > 256) {
    return "App ID 或 App Secret 长度异常";
  }
  if (credentials.verificationToken.length > 512 || credentials.encryptKey.length > 512) {
    return "Verification Token 或 Encrypt Key 长度异常";
  }
  return null;
}

function encryptCredential(value, config) {
  const key = credentialEncryptionKey(config);
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(String(value), "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `v1.${iv.toString("base64url")}.${tag.toString("base64url")}.${encrypted.toString("base64url")}`;
}

function credentialEncryptionKey(config) {
  const secret = config.feishuCredentialsKey || config.supabaseServiceRoleKey;
  return crypto.createHash("sha256").update(String(secret)).digest();
}

function randomToken(bytes) {
  return crypto.randomBytes(bytes).toString("base64url");
}

function makePairingCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.randomBytes(8);
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join("");
}

function headerValue(headers, name) {
  return headers?.[name] || headers?.[name.toLowerCase()] || headers?.[name.toUpperCase()] || "";
}

function parseJSON(value) {
  try {
    return typeof value === "string" ? JSON.parse(value) : value;
  } catch {
    return null;
  }
}

function sanitizeText(value) {
  return String(value || "").replace(/\u0000/g, "").trim();
}

function trimTrailingSlash(value) {
  return String(value || "").replace(/\/+$/, "");
}

function safeError(error) {
  return safeErrorText(error?.message || error);
}

function safeErrorText(value) {
  return String(value || "")
    .replace(/app_secret["':\s]+[A-Za-z0-9._-]+/gi, "app_secret [redacted]")
    .replace(/tenant_access_token["':\s]+[A-Za-z0-9._-]+/gi, "tenant_access_token [redacted]")
    .slice(0, 500);
}
