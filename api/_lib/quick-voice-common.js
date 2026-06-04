import crypto from "node:crypto";
import http2 from "node:http2";

export const DEFAULT_SUPABASE_URL = "https://ayzmmchrepbtfnjegqxp.supabase.co";
export const DEFAULT_APNS_BUNDLE_ID = "app.mindrop.ios";
export const INVALID_ACTIVITY_TOKEN_REASONS = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "Unregistered",
]);

export function setCorsHeaders(response) {
  response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  response.setHeader("Access-Control-Allow-Headers", "Content-Type");
}

export async function readJSONBody(request) {
  if (request.body && typeof request.body === "object") {
    return request.body;
  }

  if (typeof request.body === "string") {
    return JSON.parse(request.body || "{}");
  }

  return {};
}

export function loadQuickVoiceConfig() {
  return {
    supabaseURL: trimTrailingSlash(process.env.SUPABASE_URL || DEFAULT_SUPABASE_URL),
    supabaseServiceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY,
    apnsTeamID: process.env.APNS_TEAM_ID,
    apnsKeyID: process.env.APNS_KEY_ID,
    apnsPrivateKey: normalizePrivateKey(process.env.APNS_PRIVATE_KEY),
    apnsBundleID: process.env.APNS_BUNDLE_ID || DEFAULT_APNS_BUNDLE_ID,
    apnsEnvironment: process.env.APNS_ENVIRONMENT === "sandbox" ? "sandbox" : "production",
    remotePushDebug: process.env.REMOTE_PUSH_DEBUG === "1",
    publicURL: trimTrailingSlash(process.env.MINDROP_PUBLIC_URL || ""),
  };
}

export function missingConfigKeys(config, keys) {
  const required = {
    SUPABASE_SERVICE_ROLE_KEY: config.supabaseServiceRoleKey,
    APNS_TEAM_ID: config.apnsTeamID,
    APNS_KEY_ID: config.apnsKeyID,
    APNS_PRIVATE_KEY: config.apnsPrivateKey,
  };
  return keys.filter((key) => !required[key]);
}

export function normalizeEnvironment(value, fallback = "production") {
  return value === "sandbox" || value === "production" ? value : fallback;
}

export function sanitizeID(value, maxLength = 120) {
  return String(value || "").trim().slice(0, maxLength);
}

export function sanitizeToken(value) {
  const token = String(value || "").replace(/\s+/g, "").toLowerCase();
  return /^[a-f0-9]{32,512}$/.test(token) ? token : "";
}

export function hashDeviceSecret(secret) {
  return crypto.createHash("sha256").update(String(secret || ""), "utf8").digest("hex");
}

export function timingSafeEqualText(a, b) {
  const lhs = Buffer.from(String(a || ""), "utf8");
  const rhs = Buffer.from(String(b || ""), "utf8");
  return lhs.length === rhs.length && crypto.timingSafeEqual(lhs, rhs);
}

export async function supabaseFetch(config, path, options = {}) {
  const response = await fetch(`${config.supabaseURL}${path}`, {
    method: options.method || "GET",
    headers: {
      apikey: config.supabaseServiceRoleKey,
      authorization: `Bearer ${config.supabaseServiceRoleKey}`,
      "content-type": "application/json",
      ...(options.headers || {}),
    },
    body: options.body,
  });

  const text = await response.text();
  if (!response.ok) {
    throw new Error(`Supabase ${response.status}: ${safeErrorText(text)}`);
  }

  if (options.expectJSON === false || text.length === 0) {
    return null;
  }
  return JSON.parse(text);
}

export async function upsertQuickVoicePushToStartToken(config, input) {
  const now = new Date().toISOString();
  const body = [{
    device_id: input.deviceID,
    device_secret_hash: hashDeviceSecret(input.deviceSecret),
    push_to_start_token: input.pushToStartToken,
    environment: input.environment,
    app_bundle_id: input.appBundleID || config.apnsBundleID,
    updated_at: now,
    revoked_at: null,
  }];

  return supabaseFetch(
    config,
    "/rest/v1/quick_voice_live_activity_tokens?on_conflict=device_id,environment",
    {
      method: "POST",
      headers: { Prefer: "resolution=merge-duplicates,return=representation" },
      body: JSON.stringify(body),
    }
  );
}

export async function fetchQuickVoiceTokenRecord(config, input) {
  const query = new URLSearchParams({
    select: "id,device_id,device_secret_hash,push_to_start_token,environment,app_bundle_id",
    device_id: `eq.${input.deviceID}`,
    environment: `eq.${input.environment}`,
    revoked_at: "is.null",
    limit: "1",
  });
  const rows = await supabaseFetch(config, `/rest/v1/quick_voice_live_activity_tokens?${query}`);
  return Array.isArray(rows) ? rows[0] || null : null;
}

export async function revokeQuickVoiceToken(config, tokenRecord) {
  const query = new URLSearchParams({ id: `eq.${tokenRecord.id}` });
  await supabaseFetch(config, `/rest/v1/quick_voice_live_activity_tokens?${query}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({
      revoked_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }),
    expectJSON: false,
  });
}

export async function sendQuickVoiceLiveActivityStart(config, tokenRecord, input) {
  const deliveryConfig = {
    ...config,
    apnsBundleID: tokenRecord.app_bundle_id || config.apnsBundleID,
    apnsEnvironment: normalizeEnvironment(tokenRecord.environment, config.apnsEnvironment),
  };
  const jwt = createAPNsJWT(deliveryConfig);
  const client = http2.connect(apnsOrigin(deliveryConfig.apnsEnvironment));
  const payload = JSON.stringify(liveActivityStartPayload(input));

  try {
    return await sendAPNsRequest(client, jwt, tokenRecord.push_to_start_token, payload, deliveryConfig);
  } finally {
    client.close();
  }
}

export function liveActivityStartPayload(input) {
  const now = new Date();
  const nowUnix = Math.floor(now.getTime() / 1000);
  const nowSwiftDate = swiftCodableDate(now);
  const sessionID = `remote-quick-${crypto.randomUUID()}`;
  const displayReply = withMindropSpeaker(input.reply);

  return {
    aps: {
      timestamp: nowUnix,
      event: "start",
      "input-push-token": 1,
      "attributes-type": "MindropQuickVoiceActivityAttributes",
      attributes: {
        sessionID,
        startedAt: nowSwiftDate,
        isDiagnostic: false,
      },
      "content-state": {
        phase: "completed",
        transcript: truncateActivityText(input.transcript, 160),
        response: truncateActivityText(displayReply, 180),
        updatedAt: nowSwiftDate,
        waveformSeed: Math.floor(Math.random() * 1000),
      },
      alert: {
        title: "小落处理好了",
        body: truncateActivityText(displayReply, 120),
        sound: "default",
      },
    },
  };
}

export function originFromRequest(request, config) {
  const host = request.headers?.host || request.headers?.["x-forwarded-host"];
  if (host) {
    const protocol = request.headers?.["x-forwarded-proto"] || "https";
    return `${protocol}://${host}`;
  }
  return config.publicURL || "";
}

export function safeErrorText(value) {
  return String(value || "").slice(0, 500);
}

function trimTrailingSlash(value) {
  return String(value || "").replace(/\/+$/, "");
}

function normalizePrivateKey(value) {
  if (!value) {
    return "";
  }
  return value.replace(/\\n/g, "\n").trim();
}

function apnsOrigin(environment) {
  return environment === "sandbox"
    ? "https://api.sandbox.push.apple.com"
    : "https://api.push.apple.com";
}

function createAPNsJWT(config) {
  const header = base64URLJSON({ alg: "ES256", kid: config.apnsKeyID });
  const payload = base64URLJSON({
    iss: config.apnsTeamID,
    iat: Math.floor(Date.now() / 1000),
  });
  const signingInput = `${header}.${payload}`;
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key: config.apnsPrivateKey,
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${base64URL(signature)}`;
}

function base64URLJSON(value) {
  return base64URL(Buffer.from(JSON.stringify(value)));
}

function base64URL(value) {
  return Buffer.from(value)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

function sendAPNsRequest(client, jwt, token, payload, config) {
  return new Promise((resolve) => {
    let status = 0;
    let data = "";
    let apnsID = "";
    const request = client.request({
      ":method": "POST",
      ":path": `/3/device/${token}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": `${config.apnsBundleID}.push-type.liveactivity`,
      "apns-push-type": "liveactivity",
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 60),
    });

    request.setEncoding("utf8");
    request.on("response", (headers) => {
      status = Number(headers[":status"] || 0);
      apnsID = String(headers["apns-id"] || "");
    });
    request.on("data", (chunk) => {
      data += chunk;
    });
    request.on("error", (error) => {
      resolve({ ok: false, reason: error.message });
    });
    request.on("end", () => {
      const body = parseJSON(data);
      resolve({
        ok: status >= 200 && status < 300,
        status,
        reason: body?.reason,
        apnsID,
      });
    });
    request.end(payload);
  });
}

function parseJSON(value) {
  try {
    return value ? JSON.parse(value) : null;
  } catch {
    return null;
  }
}

function swiftCodableDate(date) {
  return date.getTime() / 1000 - 978307200;
}

function withMindropSpeaker(reply) {
  const text = String(reply || "已完成").trim();
  if (text.startsWith("小落")) {
    return text;
  }
  return `小落：${text}`;
}

function truncateActivityText(value, maxLength) {
  const text = String(value || "").replace(/\s+/g, " ").trim();
  return Array.from(text).slice(0, maxLength).join("");
}
