const ANTHROPIC_BASE_URL = process.env.ANTHROPIC_BASE_URL || "https://ark.cn-beijing.volces.com/api/coding";
const ANTHROPIC_AUTH_TOKEN = process.env.ANTHROPIC_AUTH_TOKEN || process.env.ARK_API_KEY;
const ANTHROPIC_MODEL = process.env.ANTHROPIC_MODEL || process.env.ARK_MODEL || "ark-code-latest";

const SYSTEM_PROMPT = `
你是“念落 Mindrop”的内容理解与收纳助手。你必须根据用户输入完成场景分类、结构化提取和回复生成。

分类只能是以下四种之一：
- todo：待办提醒。用户表达需要做某事、记得某事、提醒某事。
- bill：账单记录。用户表达消费、收入、借出、借入、金额流水。
- qa：知识问答。用户提出问题、求方案、求解释、求建议。
- idea：灵感沉淀。用户记录想法、灵感、计划雏形、碎片念头。

输出必须是严格 JSON，不要 Markdown，不要代码块。Schema：
{
  "category": "todo|bill|qa|idea",
  "reply": "给用户看的中文回复",
  "note": {
    "title": "10个字以内",
    "content": "便签内容，简洁总结",
    "reminderAt": "ISO8601时间或null",
    "expenseAmount": 数字或null,
    "expenseCategory": "food|transit|shopping|entertainment|education|home|relationship|other|null"
  }
}

规则：
- 无法明确分类时归为 qa。
- todo：若用户没有说具体提醒时间，reminderAt 必须为 null；若有相对时间，结合当前时间和时区计算。
- todo 回复格式优先为“已总结并收纳至“待办提醒”板块”。
- bill：提取金额；账目分类映射为餐饮 food、交通 transit、购物 shopping、娱乐 entertainment、医教 education、居家 home、人情 relationship、其他 other。
- qa：reply 必须直接回答问题；note 保存本次问答，标题不超过10字。
- idea：reply 优先为“已总结并收纳至“灵感沉淀”板块”。
`;

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

  if (!ANTHROPIC_AUTH_TOKEN || !ANTHROPIC_MODEL) {
    response.status(500).json({ error: "AI service is not configured" });
    return;
  }

  const { text, now, timeZone } = request.body || {};
  if (typeof text !== "string" || text.trim().length === 0) {
    response.status(400).json({ error: "Missing text" });
    return;
  }

  try {
    const modelResponse = await fetch(anthropicMessagesURL(), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
        "x-api-key": ANTHROPIC_AUTH_TOKEN,
        Authorization: `Bearer ${ANTHROPIC_AUTH_TOKEN}`,
      },
      body: JSON.stringify({
        model: ANTHROPIC_MODEL,
        max_tokens: 1600,
        temperature: 0.2,
        system: SYSTEM_PROMPT,
        messages: [
          {
            role: "user",
            content: JSON.stringify({
              text: text.trim(),
              now,
              timeZone,
            }),
          },
        ],
      }),
    });

    const raw = await modelResponse.text();
    if (!modelResponse.ok) {
      response.status(modelResponse.status).json({ error: "Model request failed" });
      return;
    }

    const completion = JSON.parse(raw);
    const content = extractAnthropicText(completion);
    const result = normalizeResult(parseModelJSON(content), text.trim());
    response.status(200).json(result);
  } catch (error) {
    response.status(500).json({ error: "AI request failed" });
  }
}

function setCorsHeaders(response) {
  response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Access-Control-Allow-Methods", "POST,OPTIONS");
  response.setHeader("Access-Control-Allow-Headers", "Content-Type");
}

function anthropicMessagesURL() {
  const baseURL = ANTHROPIC_BASE_URL.replace(/\/+$/, "");
  return `${baseURL}/v1/messages`;
}

function extractAnthropicText(completion) {
  if (typeof completion?.content === "string") {
    return completion.content;
  }
  if (Array.isArray(completion?.content)) {
    return completion.content
      .filter((item) => item?.type === "text" && typeof item.text === "string")
      .map((item) => item.text)
      .join("");
  }
  return "";
}

function parseModelJSON(content) {
  if (typeof content !== "string") {
    throw new Error("Empty model content");
  }
  const trimmed = content.trim().replace(/^```json\s*/i, "").replace(/^```\s*/i, "").replace(/```$/i, "");
  return JSON.parse(trimmed);
}

function normalizeResult(result, sourceText) {
  const category = normalizeCategory(result?.category);
  const note = result?.note || {};
  const title = truncate(String(note.title || defaultTitle(category, sourceText)).trim(), 10);
  const content = String(note.content || sourceText).trim();
  const expenseCategory = category === "bill" ? normalizeExpenseCategory(note.expenseCategory) : null;
  const expenseAmount = category === "bill" && Number.isFinite(Number(note.expenseAmount))
    ? Number(note.expenseAmount)
    : null;

  return {
    category,
    reply: String(result?.reply || defaultReply(category)).trim(),
    note: {
      title,
      content,
      reminderAt: category === "todo" && typeof note.reminderAt === "string" ? note.reminderAt : null,
      expenseAmount,
      expenseCategory,
    },
  };
}

function normalizeCategory(category) {
  return ["todo", "bill", "qa", "idea"].includes(category) ? category : "qa";
}

function normalizeExpenseCategory(category) {
  const values = ["food", "transit", "shopping", "entertainment", "education", "home", "relationship", "other"];
  return values.includes(category) ? category : "other";
}

function defaultReply(category) {
  switch (category) {
    case "todo":
      return "已总结并收纳至“待办提醒”板块";
    case "bill":
      return "已识别金额与账目类型，并收纳至“账单记录”板块";
    case "idea":
      return "已总结并收纳至“灵感沉淀”板块";
    default:
      return "我先给你一个可执行答案，并可以把这次问答保存至灵感沉淀。";
  }
}

function defaultTitle(category, sourceText) {
  const clean = sourceText.replace(/[，。？！?！\n]/g, " ").trim();
  if (clean.length > 0) return clean;
  return category === "todo" ? "待办提醒" : category === "bill" ? "账单记录" : category === "idea" ? "灵感沉淀" : "知识问答";
}

function truncate(value, maxLength) {
  return Array.from(value).slice(0, maxLength).join("");
}
