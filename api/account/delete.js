const DEFAULT_SUPABASE_URL = "https://ayzmmchrepbtfnjegqxp.supabase.co";

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

  const config = loadConfig();
  const missing = missingConfigKeys(config);
  if (missing.length > 0) {
    response.status(500).json({ error: "Account deletion is not configured", missing });
    return;
  }

  let user;
  try {
    user = await authenticateUser(config, request);
  } catch (error) {
    response.status(401).json({ error: safeError(error) || "Unauthorized" });
    return;
  }

  try {
    await deleteAccountData(config, user.id);
    await deleteAuthUser(config, user.id);
    response.status(200).json({ deleted: true });
  } catch (error) {
    console.error("Mindrop account deletion failed", user.id, safeError(error));
    response.status(500).json({ error: "账号注销失败，请稍后再试" });
  }
}

function loadConfig() {
  return {
    supabaseURL: trimTrailingSlash(process.env.SUPABASE_URL || DEFAULT_SUPABASE_URL),
    supabaseServiceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY,
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
    headers: serviceHeaders(config, match[1]),
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

async function deleteAccountData(config, userID) {
  const connectionIDs = await fetchFeishuConnectionIDs(config, userID);
  for (const connectionID of connectionIDs) {
    await bestEffortSupabaseDelete(config, "/rest/v1/feishu_message_events", {
      connection_id: `eq.${connectionID}`,
    });
  }

  const deletionTargets = [
    "feishu_message_events",
    "feishu_bot_connections",
    "push_tokens",
    "profile_note_stats",
    "profile_message_stats",
    "thought_notes",
    "chat_messages",
    "user_settings",
    "profiles",
    "app_snapshots",
  ];

  for (const table of deletionTargets) {
    await bestEffortSupabaseDelete(config, `/rest/v1/${table}`, {
      user_id: `eq.${userID}`,
    });
  }

  await bestEffortStorageDelete(config, `/storage/v1/object/avatars/${encodeURIComponent(userID)}/avatar.jpg`);
}

async function fetchFeishuConnectionIDs(config, userID) {
  try {
    const query = new URLSearchParams({
      select: "id",
      user_id: `eq.${userID}`,
    });
    const rows = await supabaseFetch(config, `/rest/v1/feishu_bot_connections?${query}`);
    return Array.isArray(rows) ? rows.map((row) => row?.id).filter(Boolean) : [];
  } catch (error) {
    console.warn("Mindrop account deletion: failed to fetch Feishu connections", safeError(error));
    return [];
  }
}

async function bestEffortSupabaseDelete(config, path, filters) {
  try {
    const query = new URLSearchParams(filters);
    await supabaseFetch(config, `${path}?${query}`, {
      method: "DELETE",
      headers: { Prefer: "return=minimal" },
      expectJSON: false,
    });
  } catch (error) {
    if (!isIgnorableCleanupError(error)) {
      console.warn("Mindrop account deletion cleanup skipped", path, safeError(error));
    }
  }
}

async function bestEffortStorageDelete(config, path) {
  try {
    await supabaseFetch(config, path, {
      method: "DELETE",
      expectJSON: false,
    });
  } catch (error) {
    if (!isIgnorableCleanupError(error)) {
      console.warn("Mindrop account deletion storage cleanup skipped", safeError(error));
    }
  }
}

async function deleteAuthUser(config, userID) {
  const authResponse = await fetch(
    `${config.supabaseURL}/auth/v1/admin/users/${encodeURIComponent(userID)}`,
    {
      method: "DELETE",
      headers: serviceHeaders(config),
      body: JSON.stringify({ should_soft_delete: false }),
    }
  );
  const text = await authResponse.text();
  if (!authResponse.ok) {
    throw new Error(`Supabase Auth ${authResponse.status}: ${safeErrorText(text)}`);
  }
}

async function supabaseFetch(config, path, options = {}) {
  const supabaseResponse = await fetch(`${config.supabaseURL}${path}`, {
    method: options.method || "GET",
    headers: {
      ...serviceHeaders(config),
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

function serviceHeaders(config, accessToken = config.supabaseServiceRoleKey) {
  return {
    apikey: config.supabaseServiceRoleKey,
    authorization: `Bearer ${accessToken}`,
    "content-type": "application/json",
  };
}

function isIgnorableCleanupError(error) {
  const message = safeError(error).toLowerCase();
  return (
    message.includes("404") ||
    message.includes("does not exist") ||
    message.includes("could not find") ||
    message.includes("schema cache")
  );
}

function setCorsHeaders(response) {
  response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Access-Control-Allow-Methods", "POST,OPTIONS");
  response.setHeader("Access-Control-Allow-Headers", "Content-Type,Authorization");
}

function headerValue(headers, name) {
  const value = headers[name] || headers[name.toLowerCase()];
  return Array.isArray(value) ? value[0] || "" : String(value || "");
}

function trimTrailingSlash(value) {
  return String(value || "").replace(/\/+$/, "");
}

function parseJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function safeError(error) {
  return error instanceof Error ? error.message : String(error || "");
}

function safeErrorText(value) {
  if (!value) {
    return "";
  }
  if (typeof value !== "string") {
    return safeErrorText(JSON.stringify(value));
  }
  const payload = parseJSON(value);
  return payload?.error_description || payload?.message || payload?.msg || payload?.error || value;
}
