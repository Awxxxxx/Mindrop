import {
  loadQuickVoiceConfig,
  missingConfigKeys,
  normalizeEnvironment,
  readJSONBody,
  safeErrorText,
  sanitizeID,
  sanitizeToken,
  setCorsHeaders,
  upsertQuickVoicePushToStartToken,
} from "../_lib/quick-voice-common.js";

export default async function handler(request, response) {
  setCorsHeaders(response);

  if (request.method === "OPTIONS") {
    response.status(204).end();
    return;
  }

  if (request.method !== "POST") {
    response.status(405).json({ error: "Method not allowed" });
    return;
  }

  const config = loadQuickVoiceConfig();
  const missing = missingConfigKeys(config, ["SUPABASE_SERVICE_ROLE_KEY"]);
  if (missing.length > 0) {
    response.status(500).json({ error: "Quick voice token storage is not configured", missing });
    return;
  }

  let body;
  try {
    body = await readJSONBody(request);
  } catch {
    response.status(400).json({ error: "Invalid JSON request body" });
    return;
  }

  const input = {
    deviceID: sanitizeID(body?.deviceID),
    deviceSecret: sanitizeID(body?.deviceSecret, 256),
    pushToStartToken: sanitizeToken(body?.pushToStartToken),
    environment: normalizeEnvironment(body?.environment, config.apnsEnvironment),
    appBundleID: sanitizeID(body?.appBundleID || config.apnsBundleID, 120),
  };

  if (!input.deviceID || !input.deviceSecret || !input.pushToStartToken) {
    response.status(400).json({ error: "Missing device identity or push-to-start token" });
    return;
  }

  try {
    const rows = await upsertQuickVoicePushToStartToken(config, input);
    if (config.remotePushDebug) {
      console.log("Mindrop quick voice push-to-start token registered", {
        deviceID: input.deviceID,
        environment: input.environment,
        tokenPrefix: input.pushToStartToken.slice(0, 12),
        recordID: rows?.[0]?.id || null,
      });
    }
    response.status(200).json({ ok: true });
  } catch (error) {
    console.error("Mindrop quick voice token registration failed", error);
    response.status(500).json({
      error: "Quick voice token registration failed",
      detail: safeErrorText(error?.message),
    });
  }
}
