import crypto from "node:crypto";
import http2 from "node:http2";

const DEFAULT_SUPABASE_URL = "https://ayzmmchrepbtfnjegqxp.supabase.co";
const DEFAULT_APNS_BUNDLE_ID = "app.mindrop.ios";
const MAX_BATCH_SIZE = 50;
const INVALID_TOKEN_REASONS = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "Unregistered",
]);

export default async function handler(request, response) {
  if (request.method !== "GET") {
    response.status(405).json({ error: "Method not allowed" });
    return;
  }

  if (!isAuthorized(request)) {
    response.status(401).json({ error: "Unauthorized" });
    return;
  }

  const config = loadConfig();
  const missing = missingConfigKeys(config);
  if (missing.length > 0) {
    response.status(500).json({ error: "Remote push is not configured", missing });
    return;
  }

  try {
    const reminders = await claimDueReminders(config);
    const result = await sendReminderBatch(reminders, config);
    if (config.remotePushDebug && reminders.length > 0) {
      console.log("Mindrop remote reminder push summary", {
        claimed: reminders.length,
        ...result,
        environment: config.apnsEnvironment,
      });
    }
    response.status(200).json({ ok: true, claimed: reminders.length, ...result });
  } catch (error) {
    console.error("Mindrop remote reminder push failed", error);
    response.status(500).json({ error: "Remote reminder push failed" });
  }
}

function isAuthorized(request) {
  const secret = process.env.CRON_SECRET;
  if (!secret) {
    return false;
  }
  return request.headers.authorization === `Bearer ${secret}`;
}

function loadConfig() {
  return {
    supabaseURL: trimTrailingSlash(process.env.SUPABASE_URL || DEFAULT_SUPABASE_URL),
    supabaseServiceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY,
    apnsTeamID: process.env.APNS_TEAM_ID,
    apnsKeyID: process.env.APNS_KEY_ID,
    apnsPrivateKey: normalizePrivateKey(process.env.APNS_PRIVATE_KEY),
    apnsBundleID: process.env.APNS_BUNDLE_ID || DEFAULT_APNS_BUNDLE_ID,
    apnsEnvironment: process.env.APNS_ENVIRONMENT === "sandbox" ? "sandbox" : "production",
    remotePushDebug: process.env.REMOTE_PUSH_DEBUG === "1",
  };
}

function missingConfigKeys(config) {
  const required = [
    ["SUPABASE_SERVICE_ROLE_KEY", config.supabaseServiceRoleKey],
    ["APNS_TEAM_ID", config.apnsTeamID],
    ["APNS_KEY_ID", config.apnsKeyID],
    ["APNS_PRIVATE_KEY", config.apnsPrivateKey],
  ];
  return required.filter(([, value]) => !value).map(([key]) => key);
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

async function claimDueReminders(config) {
  return supabaseFetch(config, "/rest/v1/rpc/claim_due_reminder_pushes", {
    method: "POST",
    body: JSON.stringify({ max_count: MAX_BATCH_SIZE }),
  });
}

async function sendReminderBatch(reminders, config) {
  if (reminders.length === 0) {
    return { sent: 0, failed: 0, tokensRevoked: 0 };
  }

  const jwt = createAPNsJWT(config);
  const client = http2.connect(apnsOrigin(config.apnsEnvironment));
  let sent = 0;
  let failed = 0;
  let tokensRevoked = 0;

  try {
    for (const reminder of reminders) {
      const tokens = await fetchPushTokens(config, reminder.user_id);
      if (tokens.length === 0) {
        failed += 1;
        await markReminderPushError(config, reminder.id, "No active APNs token");
        continue;
      }

      const deliveries = await Promise.all(
        tokens.map(async (tokenRecord) => {
          const delivery = await sendAPNsNotification(client, jwt, tokenRecord.token, reminder, config);
          if (!delivery.ok && INVALID_TOKEN_REASONS.has(delivery.reason)) {
            await revokePushToken(config, tokenRecord);
            tokensRevoked += 1;
          }
          return {
            ...delivery,
            tokenID: tokenRecord.id,
          };
        })
      );

      if (config.remotePushDebug) {
        console.log("Mindrop remote reminder push delivery", {
          reminderID: reminder.id,
          userID: reminder.user_id,
          environment: config.apnsEnvironment,
          tokenCount: tokens.length,
          deliveries: deliveries.map((delivery) => ({
            tokenID: delivery.tokenID,
            ok: delivery.ok,
            status: delivery.status,
            reason: delivery.reason,
            apnsID: delivery.apnsID,
          })),
        });
      }

      const successCount = deliveries.filter((delivery) => delivery.ok).length;
      if (successCount > 0) {
        sent += 1;
        await markReminderPushSent(config, reminder);
      } else {
        failed += 1;
        const reasons = deliveries.map((delivery) => delivery.reason || delivery.status || "unknown").join(", ");
        await markReminderPushError(config, reminder.id, reasons);
      }
    }
  } finally {
    client.close();
  }

  return { sent, failed, tokensRevoked };
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

async function fetchPushTokens(config, userID) {
  const query = new URLSearchParams({
    select: "id,token,environment",
    user_id: `eq.${userID}`,
    environment: `eq.${config.apnsEnvironment}`,
    revoked_at: "is.null",
  });
  return supabaseFetch(config, `/rest/v1/push_tokens?${query}`);
}

function sendAPNsNotification(client, jwt, deviceToken, reminder, config) {
  const payload = JSON.stringify({
    aps: {
      alert: {
        title: notificationTitle(reminder),
        body: notificationBody(reminder),
      },
      sound: "default",
    },
    mindrop: {
      note_id: reminder.id,
      reminder_at: reminder.reminder_at,
    },
  });

  return new Promise((resolve) => {
    let status = 0;
    let data = "";
    let apnsID = "";
    const request = client.request({
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": config.apnsBundleID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
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

function notificationTitle(reminder) {
  return sanitizeNotificationText(
    reminder.reminder_notification_title || reminder.title || "待办时间到啦",
    30
  );
}

function notificationBody(reminder) {
  return sanitizeNotificationText(
    reminder.reminder_notification_body || reminder.content || "有一条待办到了提醒时间。",
    120
  );
}

function sanitizeNotificationText(value, maxLength) {
  const text = String(value || "").replace(/\s+/g, " ").trim();
  return text.length > maxLength ? `${text.slice(0, maxLength - 1)}…` : text;
}

async function markReminderPushSent(config, reminder) {
  const now = new Date().toISOString();
  await patchReminder(config, reminder.id, {
    reminder_push_sent_at: now,
    reminder_push_reminder_at: reminder.reminder_at,
    reminder_push_error: null,
  });
}

async function markReminderPushError(config, reminderID, error) {
  await patchReminder(config, reminderID, {
    reminder_push_error: String(error || "Unknown APNs error").slice(0, 500),
  });
}

async function patchReminder(config, reminderID, body) {
  const query = new URLSearchParams({ id: `eq.${reminderID}` });
  await supabaseFetch(config, `/rest/v1/thought_notes?${query}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(body),
    expectJSON: false,
  });
}

async function revokePushToken(config, tokenRecord) {
  const query = new URLSearchParams({
    id: `eq.${tokenRecord.id}`,
  });
  await supabaseFetch(config, `/rest/v1/push_tokens?${query}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({
      revoked_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }),
    expectJSON: false,
  });
}

async function supabaseFetch(config, path, options = {}) {
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

function parseJSON(value) {
  try {
    return value ? JSON.parse(value) : null;
  } catch {
    return null;
  }
}

function safeErrorText(value) {
  return String(value || "").slice(0, 500);
}
