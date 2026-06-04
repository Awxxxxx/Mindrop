import {
  fetchQuickVoiceTokenRecord,
  hashDeviceSecret,
  INVALID_ACTIVITY_TOKEN_REASONS,
  loadQuickVoiceConfig,
  missingConfigKeys,
  normalizeEnvironment,
  originFromRequest,
  readJSONBody,
  revokeQuickVoiceToken,
  safeErrorText,
  sanitizeID,
  sendQuickVoiceLiveActivityStart,
  setCorsHeaders,
  timingSafeEqualText,
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
  const missing = missingConfigKeys(config, [
    "SUPABASE_SERVICE_ROLE_KEY",
    "APNS_TEAM_ID",
    "APNS_KEY_ID",
    "APNS_PRIVATE_KEY",
  ]);
  if (missing.length > 0) {
    response.status(500).json({ error: "Quick voice live activity is not configured", missing });
    return;
  }

  let body;
  try {
    body = await readJSONBody(request);
  } catch {
    response.status(400).json({ error: "Invalid JSON request body" });
    return;
  }

  const text = String(body?.text || "").trim();
  const identity = {
    deviceID: sanitizeID(body?.deviceID),
    deviceSecret: sanitizeID(body?.deviceSecret, 256),
    environment: normalizeEnvironment(body?.environment, config.apnsEnvironment),
  };

  if (!text) {
    response.status(400).json({ error: "Missing text" });
    return;
  }
  if (!identity.deviceID || !identity.deviceSecret) {
    response.status(400).json({ error: "Missing device identity" });
    return;
  }

  try {
    const tokenRecord = await fetchQuickVoiceTokenRecord(config, identity);
    if (!tokenRecord) {
      response.status(404).json({ error: "No active quick voice push-to-start token" });
      return;
    }

    const expectedSecretHash = hashDeviceSecret(identity.deviceSecret);
    if (!timingSafeEqualText(expectedSecretHash, tokenRecord.device_secret_hash)) {
      response.status(401).json({ error: "Invalid device identity" });
      return;
    }

    const aiResult = await requestAIAnalysis(request, config, {
      text,
      context: body?.context,
      reminders: body?.reminders,
      qaNotes: body?.qaNotes,
      now: body?.now,
      timeZone: body?.timeZone,
      thinkingEnabled: body?.thinkingEnabled === true,
    });

    const delivery = await sendQuickVoiceLiveActivityStart(config, tokenRecord, {
      transcript: text,
      reply: aiResult?.reply,
    });

    if (!delivery.ok && INVALID_ACTIVITY_TOKEN_REASONS.has(delivery.reason)) {
      await revokeQuickVoiceToken(config, tokenRecord);
    }

    if (config.remotePushDebug) {
      console.log("Mindrop quick voice capture processed", {
        deviceID: identity.deviceID,
        environment: identity.environment,
        category: aiResult?.category,
        action: aiResult?.action,
        liveActivityDelivered: delivery.ok,
        liveActivityStatus: delivery.status,
        liveActivityReason: delivery.reason,
        apnsID: delivery.apnsID,
      });
    }

    response.status(200).json({
      ...aiResult,
      _quickVoiceLiveActivity: {
        ok: delivery.ok,
        status: delivery.status,
        reason: delivery.reason || null,
        apnsID: delivery.apnsID || null,
      },
    });
  } catch (error) {
    console.error("Mindrop quick voice capture failed", error);
    response.status(500).json({
      error: "Quick voice capture failed",
      detail: safeErrorText(error?.message),
    });
  }
}

async function requestAIAnalysis(request, config, input) {
  const origin = originFromRequest(request, config);
  if (!origin) {
    throw new Error("Missing request origin");
  }

  const aiResponse = await fetch(`${origin}/api/mindrop-ai`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(input),
  });
  const raw = await aiResponse.text();
  if (!aiResponse.ok) {
    throw new Error(`AI service ${aiResponse.status}: ${safeErrorText(raw)}`);
  }
  return JSON.parse(raw);
}
