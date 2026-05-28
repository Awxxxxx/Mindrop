import crypto from "node:crypto";
import mindropAIHandler from "../mindrop-ai.js";

const DEFAULT_SUPABASE_URL = "https://ayzmmchrepbtfnjegqxp.supabase.co";
const FEISHU_API_BASE = "https://open.feishu.cn/open-apis";
const MAX_TEXT_LENGTH = 2000;
const TYPING_REACTION_EMOJI_TYPE = "Typing";
const MAX_STALE_MESSAGE_AGE_MS = 10 * 60 * 1000;
const PRE_PAIR_CLOCK_SKEW_MS = 30 * 1000;
const AI_RETRY_DELAY_MS = 350;
const PROCESSING_FAILED_REPLY = "小落刚才处理失败了，这条没有成功收纳。你可以稍后再发一次。";

const cachedTenantTokens = new Map();

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

  const callbackToken = connectionTokenFromRequest(request);
  if (!callbackToken) {
    response.status(400).json({ error: "Missing Feishu connection token" });
    return;
  }

  let connection;
  try {
    connection = await fetchFeishuConnection(config, callbackToken);
  } catch (error) {
    console.error("Mindrop Feishu connection lookup failed", safeError(error));
    response.status(500).json({ error: "Connection lookup failed" });
    return;
  }

  if (!connection || connection.revokedAt || connection.status === "revoked") {
    response.status(404).json({ error: "Feishu connection not found" });
    return;
  }

  const bodyInfo = await readRawBody(request);
  const rawBody = bodyInfo.text;
  const envelope = parseJSON(rawBody || "{}");

  if (!envelope) {
    response.status(400).json({ error: "Invalid JSON" });
    return;
  }

  let payload;
  try {
    payload = unwrapEventPayload(envelope, request.headers, rawBody, bodyInfo.exact, connection);
  } catch (error) {
    console.error("Mindrop Feishu event validation failed", safeError(error));
    response.status(401).json({ error: "Unauthorized" });
    return;
  }

  if (payload?.type === "url_verification") {
    if (!isValidVerificationToken(payload, connection)) {
      response.status(401).json({ error: "Invalid token" });
      return;
    }
    response.status(200).json({ challenge: payload.challenge });
    return;
  }

  if (!isValidVerificationToken(payload, connection)) {
    response.status(401).json({ error: "Invalid token" });
    return;
  }

  const eventType = payload?.header?.event_type || payload?.event?.type;
  if (eventType !== "im.message.receive_v1") {
    response.status(200).json({ ok: true, ignored: true });
    return;
  }

  const event = normalizeMessageEvent(payload, connection.id);
  if (!event.eventID || !event.messageID) {
    response.status(200).json({ ok: true, ignored: true });
    return;
  }

  try {
    const claimed = await claimEventRecord(config, connection, event);
    if (!claimed.shouldProcess) {
      logFeishuStage("duplicate_skipped", connection, event, { status: claimed.status });
      response.status(200).json({ ok: true, duplicate: true, status: claimed.status });
      return;
    }
    if (claimed.resumed) {
      logFeishuStage("duplicate_resumed", connection, event, { status: claimed.status });
    }

    const processResult = await processMessageEvent(config, connection, event);
    await markEventRecord(config, event.eventID, processResult.status, {
      userID: processResult.userID,
      error: processResult.error,
    });

    response.status(200).json({ ok: true, status: processResult.status });
  } catch (error) {
    console.error("Mindrop Feishu event failed", safeError(error));
    await markEventRecord(config, event.eventID, "error", { error: safeError(error) }).catch(() => {});
    await insertFailureChatMessage(config, connection, event).catch(() => {});
    await replyToFeishuMessage(connection, event, PROCESSING_FAILED_REPLY).catch(() => {});
    response.status(200).json({ ok: true, status: "error" });
  }
}

function loadConfig() {
  return {
    supabaseURL: trimTrailingSlash(process.env.SUPABASE_URL || DEFAULT_SUPABASE_URL),
    supabaseServiceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY,
    feishuCredentialsKey: process.env.FEISHU_CREDENTIALS_KEY,
  };
}

function missingConfigKeys(config) {
  return [["SUPABASE_SERVICE_ROLE_KEY", config.supabaseServiceRoleKey]]
    .filter(([, value]) => !value)
    .map(([key]) => key);
}

async function processMessageEvent(config, connection, event) {
  if (event.chatType !== "p2p") {
    await replyToFeishuMessage(connection, event, "Mindrop 目前只支持和 Bot 单聊收纳。");
    return { status: "ignored" };
  }

  if (event.senderType && event.senderType !== "user") {
    return { status: "ignored" };
  }

  const text = extractTextMessage(event);
  if (!text) {
    await replyToFeishuMessage(connection, event, "小落现在只支持文字消息。");
    return { status: "ignored" };
  }

  const bindCode = parseBindCode(text);
  if (bindCode) {
    const linked = await bindFeishuConnection(config, connection, event, bindCode);
    const reply = linked
      ? "绑定成功。之后你在这里发给小落的文字，会同步收纳到 Mindrop。"
      : "绑定码无效、已过期，或这个 Bot 已绑定到其他飞书用户。请在 Mindrop 里重新生成。";
    await replyToFeishuMessage(connection, event, reply);
    return { status: linked ? "processed" : "ignored", userID: linked?.user_id };
  }

  if (isUnbindCommand(text)) {
    const userID = await revokeFeishuConnection(config, connection, event);
    await replyToFeishuMessage(connection, event, "已解除飞书绑定。");
    return { status: "processed", userID };
  }

  if (shouldIgnoreNormalMessageByTime(connection, event)) {
    return { status: "ignored", userID: connection.userID };
  }

  if (!connection.pairedOpenID || connection.status !== "paired") {
    await replyToFeishuMessage(connection, event, "请先在 Mindrop 里完成“飞书配对”，再发送绑定码。");
    return { status: "ignored" };
  }

  if (connection.pairedOpenID !== event.openID) {
    await replyToFeishuMessage(connection, event, "这个 Bot 已绑定到另一个飞书用户。");
    return { status: "ignored" };
  }

  const typingReactionID = await addFeishuTypingReaction(connection, event);
  try {
    await touchConnection(config, connection, event);
    const now = new Date();
    const messageIDs = feishuMessageIDs(connection, event);
    const context = await fetchRecentContext(config, connection.userID);
    const reminders = await fetchReminderCandidates(config, connection.userID);
    const qaNotes = await fetchQACandidates(config, connection.userID);
    await insertChatMessage(config, {
      userID: connection.userID,
      role: "user",
      text,
      category: null,
      noteID: null,
      id: messageIDs.user,
      now,
    });
    logFeishuStage("user_message_inserted", connection, event);

    const analysis = await analyzeText({
      text,
      now: now.toISOString(),
      timeZone: connection.timeZone || "Asia/Shanghai",
      context,
      reminders,
      qaNotes,
    });
    logFeishuStage("ai_analyzed", connection, event, {
      action: analysis.action || "createNote",
      category: analysis.category,
      replyChars: String(analysis.reply || "").length,
    });
    const noteID = await applyAnalysis(
      config,
      connection.userID,
      analysis,
      now,
      messageIDs.note
    );
    logFeishuStage("note_applied", connection, event, { noteID });
    await insertChatMessage(config, {
      userID: connection.userID,
      role: "assistant",
      text: analysis.reply,
      category: categoryToRawValue(analysis.category),
      noteID,
      id: messageIDs.assistant,
      now: new Date(),
    });
    logFeishuStage("assistant_message_inserted", connection, event, { noteID });
    await replyToFeishuMessage(connection, event, analysis.reply);
    return { status: "processed", userID: connection.userID };
  } finally {
    await deleteFeishuReaction(connection, event, typingReactionID);
  }
}

function unwrapEventPayload(envelope, headers, rawBody, rawBodyExact, connection) {
  if (typeof envelope.encrypt !== "string") {
    return envelope;
  }

  if (!connection.encryptKey) {
    throw new Error("Missing Feishu Encrypt Key");
  }

  if (rawBody && rawBodyExact) {
    verifyFeishuSignature(headers, rawBody, connection.encryptKey);
  }
  return parseJSON(decryptFeishuPayload(envelope.encrypt, connection.encryptKey));
}

function verifyFeishuSignature(headers, rawBody, encryptKey) {
  const timestamp = headerValue(headers, "x-lark-request-timestamp");
  const nonce = headerValue(headers, "x-lark-request-nonce");
  const signature = headerValue(headers, "x-lark-signature");

  if (!timestamp || !nonce || !signature) {
    return;
  }

  const expected = crypto
    .createHash("sha256")
    .update(timestamp + nonce + encryptKey)
    .update(rawBody)
    .digest("hex");

  if (!timingSafeEqual(expected, signature)) {
    throw new Error("Invalid Feishu signature");
  }
}

function decryptFeishuPayload(encrypt, encryptKey) {
  const encrypted = Buffer.from(encrypt, "base64");
  const key = crypto.createHash("sha256").update(encryptKey).digest();
  const iv = encrypted.subarray(0, 16);
  const body = encrypted.subarray(16);
  const decipher = crypto.createDecipheriv("aes-256-cbc", key, iv);
  const decrypted = Buffer.concat([decipher.update(body), decipher.final()]).toString("utf8");
  const start = decrypted.indexOf("{");
  const end = decrypted.lastIndexOf("}");
  if (start < 0 || end < start) {
    throw new Error("Invalid decrypted Feishu payload");
  }
  return decrypted.slice(start, end + 1);
}

function isValidVerificationToken(payload, connection) {
  const token = payload?.token || payload?.header?.token;
  return Boolean(connection.verificationToken && token === connection.verificationToken);
}

function normalizeMessageEvent(payload, connectionID) {
  const event = payload.event || {};
  const message = event.message || {};
  const sender = event.sender || {};
  const senderID = sender.sender_id || {};
  const messageID = message.message_id || event.message_id || "";
  return {
    connectionID,
    eventID: messageID || payload.header?.event_id,
    deliveryID: payload.header?.event_id || "",
    eventType: payload.header?.event_type,
    tenantKey: payload.header?.tenant_key || sender.tenant_key || event.tenant_key || "",
    openID: senderID.open_id || event.sender_id || "",
    senderType: sender.sender_type || "",
    chatID: message.chat_id || event.chat_id || "",
    chatType: message.chat_type || event.chat_type || "",
    messageID,
    messageType: message.message_type || event.message_type || "",
    createTime: parseFeishuTimestamp(message.create_time || event.create_time || payload.header?.create_time),
    content: message.content ?? event.content,
  };
}

function extractTextMessage(event) {
  if (event.messageType !== "text") {
    return "";
  }
  const content = typeof event.content === "string" ? parseJSON(event.content) : event.content;
  return sanitizeText(content?.text || "").slice(0, MAX_TEXT_LENGTH);
}

function parseFeishuTimestamp(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric <= 0) {
    return null;
  }
  const milliseconds = numeric > 10_000_000_000 ? numeric : numeric * 1000;
  const date = new Date(milliseconds);
  return Number.isNaN(date.getTime()) ? null : date;
}

function shouldIgnoreNormalMessageByTime(connection, event) {
  if (!event.createTime) {
    return false;
  }

  const createdAt = event.createTime.getTime();
  if (Date.now() - createdAt > MAX_STALE_MESSAGE_AGE_MS) {
    console.warn("Mindrop Feishu ignored stale message", {
      connectionID: connection.id,
      messageID: event.messageID,
      createdAt: event.createTime.toISOString(),
    });
    return true;
  }

  if (connection.status === "paired" && connection.pairingExpiresAt) {
    const pairedAt = Date.parse(connection.pairingExpiresAt);
    if (Number.isFinite(pairedAt) && createdAt + PRE_PAIR_CLOCK_SKEW_MS < pairedAt) {
      console.warn("Mindrop Feishu ignored pre-pair message", {
        connectionID: connection.id,
        messageID: event.messageID,
        createdAt: event.createTime.toISOString(),
        pairedAt: new Date(pairedAt).toISOString(),
      });
      return true;
    }
  }

  return false;
}

function parseBindCode(text) {
  const match = text.trim().match(/^(绑定|bind)\s+([A-Za-z0-9]{6,12})$/i);
  return match ? match[2].toUpperCase() : null;
}

function isUnbindCommand(text) {
  return /^(解绑|解除绑定|取消绑定|unbind)$/i.test(text.trim());
}

async function fetchFeishuConnection(config, callbackToken) {
  const query = new URLSearchParams({
    select: [
      "id",
      "user_id",
      "callback_token",
      "app_id",
      "app_secret_encrypted",
      "verification_token_encrypted",
      "encrypt_key_encrypted",
      "pairing_code",
      "pairing_expires_at",
      "paired_open_id",
      "paired_chat_id",
      "tenant_key",
      "time_zone",
      "status",
      "revoked_at",
    ].join(","),
    callback_token: `eq.${callbackToken}`,
    limit: "1",
  });
  const row = (await supabaseFetch(config, `/rest/v1/feishu_bot_connections?${query}`))[0];
  if (!row) {
    return null;
  }

  return {
    id: row.id,
    userID: row.user_id,
    appID: row.app_id,
    appSecret: decryptCredential(row.app_secret_encrypted, config),
    verificationToken: decryptCredential(row.verification_token_encrypted, config),
    encryptKey: decryptCredential(row.encrypt_key_encrypted, config),
    pairingCode: row.pairing_code,
    pairingExpiresAt: row.pairing_expires_at,
    pairedOpenID: row.paired_open_id,
    pairedChatID: row.paired_chat_id,
    tenantKey: row.tenant_key,
    timeZone: row.time_zone || "Asia/Shanghai",
    status: row.status,
    revokedAt: row.revoked_at,
  };
}

async function bindFeishuConnection(config, connection, event, code) {
  if (connection.pairedOpenID && connection.pairedOpenID !== event.openID) {
    return null;
  }
  if (!connection.pairingCode || connection.pairingCode !== code) {
    return null;
  }
  if (!connection.pairingExpiresAt || Date.parse(connection.pairingExpiresAt) <= Date.now()) {
    return null;
  }

  const now = new Date().toISOString();
  const query = new URLSearchParams({ id: `eq.${connection.id}` });
  await supabaseFetch(config, `/rest/v1/feishu_bot_connections?${query}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({
      status: "paired",
      paired_open_id: event.openID,
      paired_chat_id: event.chatID,
      tenant_key: event.tenantKey,
      pairing_code: null,
      pairing_expires_at: now,
      last_event_at: now,
      updated_at: now,
      revoked_at: null,
    }),
    expectJSON: false,
  });

  return { user_id: connection.userID };
}

async function revokeFeishuConnection(config, connection, event) {
  if (connection.pairedOpenID && connection.pairedOpenID !== event.openID) {
    return null;
  }

  const now = new Date().toISOString();
  const query = new URLSearchParams({ id: `eq.${connection.id}` });
  await supabaseFetch(config, `/rest/v1/feishu_bot_connections?${query}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({
      status: "revoked",
      revoked_at: now,
      last_event_at: now,
      updated_at: now,
    }),
    expectJSON: false,
  });
  return connection.userID;
}

async function touchConnection(config, connection, event) {
  const now = new Date().toISOString();
  const body = {
    tenant_key: event.tenantKey || null,
    last_event_at: now,
    updated_at: now,
  };
  if (event.chatID && connection.pairedOpenID === event.openID) {
    body.paired_chat_id = event.chatID;
  }
  const query = new URLSearchParams({ id: `eq.${connection.id}` });
  await supabaseFetch(config, `/rest/v1/feishu_bot_connections?${query}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(body),
    expectJSON: false,
  });
}

async function fetchRecentContext(config, userID) {
  const query = new URLSearchParams({
    select: "role,text,category,created_at",
    user_id: `eq.${userID}`,
    deleted_at: "is.null",
    order: "created_at.desc",
    limit: "10",
  });
  const rows = await supabaseFetch(config, `/rest/v1/chat_messages?${query}`);
  return rows.reverse().map((row) => ({
    role: row.role === "assistant" ? "assistant" : "user",
    text: row.text || "",
    category: row.category || null,
  }));
}

async function fetchReminderCandidates(config, userID) {
  const query = new URLSearchParams({
    select: "id,title,content,reminder_at,created_at",
    user_id: `eq.${userID}`,
    category: "eq.待办提醒",
    deleted_at: "is.null",
    reminder_at: "not.is.null",
    order: "reminder_at.asc",
    limit: "20",
  });
  const rows = await supabaseFetch(config, `/rest/v1/thought_notes?${query}`);
  return rows.map((row) => ({
    id: row.id,
    title: row.title || "",
    content: row.content || "",
    reminderAt: row.reminder_at || "",
    createdAt: row.created_at || "",
  }));
}

async function fetchQACandidates(config, userID) {
  const query = new URLSearchParams({
    select: "id,title,content,created_at",
    user_id: `eq.${userID}`,
    category: "eq.知识问答",
    deleted_at: "is.null",
    order: "updated_at.desc",
    limit: "1",
  });
  const rows = await supabaseFetch(config, `/rest/v1/thought_notes?${query}`);
  return rows.map((row) => ({
    id: row.id,
    title: row.title || "",
    content: row.content || "",
    createdAt: row.created_at || "",
  }));
}

async function analyzeText(body) {
  let lastError = null;
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    let statusCode = 200;
    let payload = null;
    const response = {
      setHeader() {},
      status(code) {
        statusCode = code;
        return this;
      },
      json(value) {
        payload = value;
        return this;
      },
      end() {
        return this;
      },
    };

    await mindropAIHandler({ method: "POST", body }, response);
    if (statusCode >= 200 && statusCode < 300) {
      return payload;
    }

    const detail = safeErrorText(payload?.detail || payload?.error || "");
    lastError = new Error(`Mindrop AI failed: ${statusCode}${detail ? ` ${detail}` : ""}`);
    if (attempt < 2) {
      await sleep(AI_RETRY_DELAY_MS);
    }
  }

  throw lastError || new Error("Mindrop AI failed");
}

async function applyAnalysis(config, userID, analysis, now, createNoteID = null) {
  const category = categoryToRawValue(analysis.category);
  const action = analysis.action || "createNote";

  if (action === "updateReminder" && analysis.targetNoteId && analysis.note?.reminderAt) {
    await patchNote(config, userID, analysis.targetNoteId, {
      title: textOrFallback(analysis.note.title, category),
      content: textOrFallback(analysis.note.content, ""),
      reminder_at: analysis.note.reminderAt,
      reminder_notification_title: null,
      reminder_notification_body: null,
      reminder_push_sent_at: null,
      reminder_push_reminder_at: null,
      reminder_push_attempted_at: null,
      reminder_push_attempt_count: 0,
      reminder_push_error: null,
      updated_at: new Date().toISOString(),
      deleted_at: null,
    });
    return analysis.targetNoteId;
  }

  if (action === "deleteReminder" && analysis.targetNoteId) {
    await patchNote(config, userID, analysis.targetNoteId, {
      category: "回收站",
      category_before_recycle: "待办提醒",
      recycled_at: new Date().toISOString(),
      reminder_at: null,
      reminder_notification_title: null,
      reminder_notification_body: null,
      updated_at: new Date().toISOString(),
      deleted_at: null,
    });
    return analysis.targetNoteId;
  }

  if (action === "updateQA" && analysis.targetNoteId) {
    await patchNote(config, userID, analysis.targetNoteId, {
      title: textOrFallback(analysis.note?.title, "知识问答"),
      content: textOrFallback(analysis.note?.content, ""),
      reminder_at: null,
      expense_amount: null,
      expense_category: null,
      updated_at: new Date().toISOString(),
      deleted_at: null,
    });
    return analysis.targetNoteId;
  }

  const noteID = createNoteID || crypto.randomUUID();
  const createdAt = now.toISOString();
  await supabaseFetch(config, "/rest/v1/thought_notes?on_conflict=id", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify({
      id: noteID,
      user_id: userID,
      title: textOrFallback(analysis.note?.title, category),
      content: textOrFallback(analysis.note?.content, ""),
      category,
      created_at: createdAt,
      updated_at: createdAt,
      deleted_at: null,
      reminder_at: analysis.category === "todo" ? analysis.note?.reminderAt || null : null,
      reminder_notification_title: null,
      reminder_notification_body: null,
      expense_amount: analysis.category === "bill" ? analysis.note?.expenseAmount || null : null,
      expense_category: analysis.category === "bill" ? expenseCategoryToRawValue(analysis.note?.expenseCategory) : null,
      is_pinned: false,
      recycled_at: null,
      category_before_recycle: null,
    }),
    expectJSON: false,
  });
  return noteID;
}

async function patchNote(config, userID, noteID, body) {
  const query = new URLSearchParams({
    id: `eq.${noteID}`,
    user_id: `eq.${userID}`,
  });
  await supabaseFetch(config, `/rest/v1/thought_notes?${query}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(body),
    expectJSON: false,
  });
}

async function insertChatMessage(config, message) {
  const now = message.now.toISOString();
  await supabaseFetch(config, "/rest/v1/chat_messages?on_conflict=id", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify({
      id: message.id || crypto.randomUUID(),
      user_id: message.userID,
      role: message.role,
      text: textOrFallback(message.text, ""),
      category: message.category,
      note_id: message.noteID,
      created_at: now,
      updated_at: now,
      deleted_at: null,
    }),
    expectJSON: false,
  });
}

async function insertFailureChatMessage(config, connection, event) {
  if (connection.status !== "paired" || connection.pairedOpenID !== event.openID) {
    return;
  }
  const messageIDs = feishuMessageIDs(connection, event);
  await insertChatMessage(config, {
    userID: connection.userID,
    role: "assistant",
    text: PROCESSING_FAILED_REPLY,
    category: null,
    noteID: null,
    id: messageIDs.assistantError,
    now: new Date(),
  });
  logFeishuStage("failure_message_inserted", connection, event);
}

async function claimEventRecord(config, connection, event) {
  const created = await supabaseFetch(config, "/rest/v1/feishu_message_events?on_conflict=event_id", {
    method: "POST",
    headers: { Prefer: "resolution=ignore-duplicates,return=representation" },
    body: JSON.stringify({
      event_id: event.eventID,
      connection_id: connection.id,
      event_type: event.eventType,
      tenant_key: event.tenantKey,
      open_id: event.openID,
      chat_id: event.chatID,
      message_id: event.messageID,
      user_id: connection.userID,
      status: "processing",
      error: null,
    }),
  });
  if (created?.[0]) {
    return { shouldProcess: true, resumed: false, status: "processing" };
  }

  const existing = await fetchEventRecord(config, event.eventID);
  if (shouldResumeEventRecord(existing)) {
    return { shouldProcess: true, resumed: true, status: existing?.status || "unknown" };
  }

  return { shouldProcess: false, resumed: false, status: existing?.status || "duplicate" };
}

async function fetchEventRecord(config, eventID) {
  const query = new URLSearchParams({
    select: "event_id,status,error,processed_at,received_at,user_id",
    event_id: `eq.${eventID}`,
    limit: "1",
  });
  const rows = await supabaseFetch(config, `/rest/v1/feishu_message_events?${query}`);
  return rows?.[0] || null;
}

function shouldResumeEventRecord(record) {
  if (!record) {
    return true;
  }
  return record.status === "processing" || record.status === "error";
}

async function markEventRecord(config, eventID, status, options = {}) {
  const query = new URLSearchParams({ event_id: `eq.${eventID}` });
  const body = {
    status,
    processed_at: new Date().toISOString(),
    error: options.error ? String(options.error).slice(0, 500) : null,
  };
  if (options.userID) {
    body.user_id = options.userID;
  }
  await supabaseFetch(config, `/rest/v1/feishu_message_events?${query}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(body),
    expectJSON: false,
  });
}

async function replyToFeishuMessage(connection, event, text) {
  if (!connection.appID || !connection.appSecret || !event?.messageID) {
    return;
  }

  try {
    const token = await internalTenantAccessToken(connection);
    const query = new URLSearchParams({ uuid: dedupeToken("reply", connection.id, event.messageID) });
    const feishuResponse = await fetch(`${FEISHU_API_BASE}/im/v1/messages/${encodeURIComponent(event.messageID)}/reply?${query}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        msg_type: "text",
        content: JSON.stringify({ text: sanitizeText(text).slice(0, 600) || "已处理。" }),
      }),
    });
    const body = await feishuResponse.text();
    const parsed = parseJSON(body);
    if (!feishuResponse.ok || (parsed?.code && parsed.code !== 0)) {
      console.error("Mindrop Feishu reply failed", safeErrorText(body || feishuResponse.status));
    }
  } catch (error) {
    console.error("Mindrop Feishu reply failed", safeError(error));
  }
}

async function addFeishuTypingReaction(connection, event) {
  if (!connection.appID || !connection.appSecret || !event?.messageID) {
    return null;
  }

  try {
    const token = await internalTenantAccessToken(connection);
    const feishuResponse = await fetch(
      `${FEISHU_API_BASE}/im/v1/messages/${encodeURIComponent(event.messageID)}/reactions`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          reaction_type: {
            emoji_type: TYPING_REACTION_EMOJI_TYPE,
          },
        }),
      }
    );
    const body = await feishuResponse.text();
    const parsed = parseJSON(body);
    if (!feishuResponse.ok || (parsed?.code && parsed.code !== 0)) {
      console.error("Mindrop Feishu typing reaction failed", safeErrorText(body || feishuResponse.status));
      return null;
    }
    return parsed?.data?.reaction_id || parsed?.reaction_id || null;
  } catch (error) {
    console.error("Mindrop Feishu typing reaction failed", safeError(error));
    return null;
  }
}

async function deleteFeishuReaction(connection, event, reactionID) {
  if (!connection.appID || !connection.appSecret || !event?.messageID || !reactionID) {
    return;
  }

  try {
    const token = await internalTenantAccessToken(connection);
    const feishuResponse = await fetch(
      `${FEISHU_API_BASE}/im/v1/messages/${encodeURIComponent(event.messageID)}/reactions/${encodeURIComponent(reactionID)}`,
      {
        method: "DELETE",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
      }
    );
    const body = await feishuResponse.text();
    const parsed = parseJSON(body);
    if (!feishuResponse.ok || (parsed?.code && parsed.code !== 0)) {
      console.error("Mindrop Feishu typing reaction cleanup failed", safeErrorText(body || feishuResponse.status));
    }
  } catch (error) {
    console.error("Mindrop Feishu typing reaction cleanup failed", safeError(error));
  }
}

async function internalTenantAccessToken(connection) {
  const cacheKey = `${connection.id}:${connection.appID}`;
  const cached = cachedTenantTokens.get(cacheKey);
  if (cached && cached.expiresAt > Date.now() + 60_000) {
    return cached.token;
  }

  const feishuResponse = await fetch(`${FEISHU_API_BASE}/auth/v3/tenant_access_token/internal`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      app_id: connection.appID,
      app_secret: connection.appSecret,
    }),
  });
  const body = await feishuResponse.text();
  if (!feishuResponse.ok) {
    throw new Error(`Feishu token failed: ${feishuResponse.status} ${safeErrorText(body)}`);
  }
  const parsed = parseJSON(body);
  if (parsed?.code !== 0 || !parsed?.tenant_access_token) {
    throw new Error(`Feishu token failed: ${parsed?.code} ${safeErrorText(parsed?.msg)}`);
  }

  const value = {
    token: parsed.tenant_access_token,
    expiresAt: Date.now() + Math.max(60, Number(parsed.expire || 7200) - 300) * 1000,
  };
  cachedTenantTokens.set(cacheKey, value);
  return value.token;
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

async function readRawBody(request) {
  if (typeof request.body === "string") {
    return { text: request.body, exact: true };
  }
  if (Buffer.isBuffer(request.body)) {
    return { text: request.body.toString("utf8"), exact: true };
  }
  if (request.body && typeof request.body === "object") {
    return { text: JSON.stringify(request.body), exact: false };
  }

  const chunks = [];
  for await (const chunk of request) {
    chunks.push(Buffer.from(chunk));
  }
  return { text: Buffer.concat(chunks).toString("utf8"), exact: true };
}

function connectionTokenFromRequest(request) {
  const url = new URL(request.url || "", "https://mindrop.local");
  return sanitizeText(url.searchParams.get("connection") || url.searchParams.get("connection_token") || "");
}

function decryptCredential(value, config) {
  const text = String(value || "");
  if (!text.startsWith("v1.")) {
    throw new Error("Invalid encrypted Feishu credential");
  }
  const [, ivValue, tagValue, encryptedValue] = text.split(".");
  const key = credentialEncryptionKey(config);
  const iv = Buffer.from(ivValue, "base64url");
  const tag = Buffer.from(tagValue, "base64url");
  const encrypted = Buffer.from(encryptedValue, "base64url");
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(encrypted), decipher.final()]).toString("utf8");
}

function credentialEncryptionKey(config) {
  const secret = config.feishuCredentialsKey || config.supabaseServiceRoleKey;
  return crypto.createHash("sha256").update(String(secret)).digest();
}

function parseJSON(value) {
  try {
    return typeof value === "string" ? JSON.parse(value) : value;
  } catch {
    return null;
  }
}

function categoryToRawValue(category) {
  switch (category) {
    case "todo": return "待办提醒";
    case "bill": return "账单记录";
    case "qa": return "知识问答";
    case "idea": return "灵感沉淀";
    default: return "灵感沉淀";
  }
}

function expenseCategoryToRawValue(category) {
  switch (category) {
    case "food": return "餐饮";
    case "transit": return "交通";
    case "shopping": return "购物";
    case "entertainment": return "娱乐";
    case "education": return "医教";
    case "home": return "居家";
    case "relationship": return "人情";
    case "other": return "其他";
    default: return null;
  }
}

function headerValue(headers, name) {
  return headers?.[name] || headers?.[name.toLowerCase()] || headers?.[name.toUpperCase()] || "";
}

function timingSafeEqual(left, right) {
  const leftBuffer = Buffer.from(String(left));
  const rightBuffer = Buffer.from(String(right));
  return leftBuffer.length === rightBuffer.length && crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function textOrFallback(value, fallback) {
  const text = sanitizeText(value);
  return text.length > 0 ? text : fallback;
}

function feishuMessageIDs(connection, event) {
  return {
    user: deterministicUUID("feishu", connection.id, event.messageID, "user"),
    assistant: deterministicUUID("feishu", connection.id, event.messageID, "assistant"),
    assistantError: deterministicUUID("feishu", connection.id, event.messageID, "assistant-error"),
    note: deterministicUUID("feishu", connection.id, event.messageID, "note"),
  };
}

function deterministicUUID(...parts) {
  const hash = crypto
    .createHash("sha256")
    .update(parts.map((part) => String(part || "")).join("\u001f"))
    .digest();
  hash[6] = (hash[6] & 0x0f) | 0x50;
  hash[8] = (hash[8] & 0x3f) | 0x80;
  const hex = hash.subarray(0, 16).toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function dedupeToken(...parts) {
  return crypto
    .createHash("sha256")
    .update(parts.map((part) => String(part || "")).join("\u001f"))
    .digest("hex")
    .slice(0, 32);
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function sanitizeText(value) {
  return String(value || "").replace(/\u0000/g, "").trim();
}

function trimTrailingSlash(value) {
  return String(value || "").replace(/\/+$/, "");
}

function logFeishuStage(stage, connection, event, details = {}) {
  console.info(JSON.stringify({
    event: "mindrop_feishu_stage",
    stage,
    connectionID: shortID(connection?.id),
    userID: shortID(connection?.userID),
    eventID: shortID(event?.eventID),
    messageID: shortID(event?.messageID),
    ...details,
  }));
}

function shortID(value) {
  const text = String(value || "");
  return text.length > 8 ? text.slice(-8) : text;
}

function safeError(error) {
  return safeErrorText(error?.message || error);
}

function safeErrorText(value) {
  return String(value || "")
    .replace(/app_secret["':\s]+[A-Za-z0-9._-]+/gi, "app_secret [redacted]")
    .replace(/tenant_access_token["':\s]+[A-Za-z0-9._-]+/gi, "tenant_access_token [redacted]")
    .replace(/app_access_token["':\s]+[A-Za-z0-9._-]+/gi, "app_access_token [redacted]")
    .slice(0, 500);
}
