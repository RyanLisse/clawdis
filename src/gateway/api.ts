import { randomUUID } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";
import { createDefaultDeps } from "../cli/deps.js";
import { agentCommand } from "../commands/agent.js";
import { onAgentEvent } from "../infra/agent-events.js";
import { defaultRuntime } from "../runtime.js";
import { authorizeGatewayConnect, type ResolvedGatewayAuth } from "./auth.js";
import { readJsonBody } from "./hooks.js";

type ApiAuthOptions = {
  auth: ResolvedGatewayAuth;
};

type OpenAIChatMessage = {
  role?: unknown;
  content?: unknown;
};

type OpenAIChatCompletionRequest = {
  model?: unknown;
  stream?: unknown;
  messages?: unknown;
};

function sendJson(res: ServerResponse, status: number, body: unknown) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}

function getBearerToken(req: IncomingMessage): string | undefined {
  const raw =
    typeof req.headers.authorization === "string"
      ? req.headers.authorization.trim()
      : "";
  if (!raw.toLowerCase().startsWith("bearer ")) return undefined;
  const token = raw.slice(7).trim();
  return token || undefined;
}

function writeSse(res: ServerResponse, data: unknown) {
  res.write(`data: ${JSON.stringify(data)}\n\n`);
}

function writeDone(res: ServerResponse) {
  res.write("data: [DONE]\n\n");
}

function coerceString(val: unknown): string {
  return typeof val === "string" ? val : "";
}

function asMessages(val: unknown): OpenAIChatMessage[] {
  return Array.isArray(val) ? (val as OpenAIChatMessage[]) : [];
}

function asRequest(val: unknown): OpenAIChatCompletionRequest {
  if (typeof val !== "object" || val === null) return {};
  return val as OpenAIChatCompletionRequest;
}

function buildAgentInputs(messagesUnknown: unknown): {
  message: string;
  extraSystemPrompt?: string;
} {
  const normalized = asMessages(messagesUnknown);

  const systemParts: string[] = [];
  const historyParts: string[] = [];

  let lastUser = "";

  for (const m of normalized) {
    const role = coerceString(m?.role);
    const content = coerceString(m?.content);
    if (!role || !content) continue;

    if (role === "system") {
      systemParts.push(content);
      continue;
    }

    if (role === "user") {
      lastUser = content;
      historyParts.push(`User: ${content}`);
      continue;
    }

    if (role === "assistant") {
      historyParts.push(`Assistant: ${content}`);
      continue;
    }

    historyParts.push(`${role}: ${content}`);
  }

  const message =
    lastUser ||
    (historyParts.length > 0 ? historyParts[historyParts.length - 1] : "");

  const extraParts: string[] = [];
  if (systemParts.length > 0) {
    extraParts.push(systemParts.join("\n\n"));
  }
  if (historyParts.length > 0) {
    extraParts.push(historyParts.join("\n"));
  }

  const extraSystemPrompt =
    extraParts.length > 0 ? extraParts.join("\n\n") : undefined;

  return { message, extraSystemPrompt };
}

export async function handleApiRequest(
  req: IncomingMessage,
  res: ServerResponse,
  opts?: ApiAuthOptions,
): Promise<boolean> {
  const url = new URL(
    req.url ?? "/",
    `http://${req.headers.host || "localhost"}`,
  );

  if (url.pathname === "/v1/chat/completions" && req.method === "POST") {
    const auth = opts?.auth;
    if (auth) {
      const token = getBearerToken(req);
      const authResult = await authorizeGatewayConnect({
        auth,
        connectAuth: {
          token,
          password: token,
        },
        req,
      });
      if (!authResult.ok && auth.mode !== "none") {
        sendJson(res, 401, {
          error: { message: "Unauthorized", type: "unauthorized" },
        });
        return true;
      }
    }

    const body = await readJsonBody(req, 1024 * 1024);
    if (!body.ok) {
      sendJson(res, 400, {
        error: { message: body.error, type: "invalid_request_error" },
      });
      return true;
    }

    const payload = asRequest(body.value);
    const stream = Boolean(payload.stream);

    const agentInputs = buildAgentInputs(payload.messages);

    const runId = randomUUID();
    const deps = createDefaultDeps();

    if (stream) {
      res.statusCode = 200;
      res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
      res.setHeader("Cache-Control", "no-cache");
      res.setHeader("Connection", "keep-alive");

      let sawAssistantDelta = false;
      let closed = false;
      const unsubscribe = onAgentEvent((evt) => {
        if (evt.runId !== runId) return;
        if (closed) return;
        if (evt.stream === "assistant") {
          const delta = evt.data?.delta;
          const text = evt.data?.text;
          const content =
            typeof delta === "string"
              ? delta
              : typeof text === "string"
                ? text
                : "";
          if (!content) return;
          sawAssistantDelta = true;
          writeSse(res, {
            id: runId,
            object: "chat.completion.chunk",
            created: Math.floor(Date.now() / 1000),
            model:
              typeof payload.model === "string"
                ? payload.model
                : "clawdbot-agent",
            choices: [
              {
                index: 0,
                delta: { content },
                finish_reason: null,
              },
            ],
          });
          return;
        }

        if (evt.stream === "lifecycle") {
          const phase = evt.data?.phase;
          if (phase === "end") {
            closed = true;
            unsubscribe();
            writeDone(res);
            res.end();
          }
        }
      });

      req.on("close", () => {
        closed = true;
        unsubscribe();
      });

      void (async () => {
        try {
          const result = await agentCommand(
            {
              message: agentInputs.message,
              extraSystemPrompt: agentInputs.extraSystemPrompt,
              runId,
              deliver: false,
              provider: "whatsapp",
              bestEffortDeliver: false,
            },
            defaultRuntime,
            deps,
          );

          if (closed) return;

          if (!sawAssistantDelta) {
            const payloads = (
              result as { payloads?: Array<{ text?: string }> } | null
            )?.payloads;
            const content =
              Array.isArray(payloads) && payloads.length > 0
                ? payloads
                    .map((p) => (typeof p.text === "string" ? p.text : ""))
                    .filter(Boolean)
                    .join("\n\n")
                : "No response from Clawdbot.";

            writeSse(res, {
              id: runId,
              object: "chat.completion.chunk",
              created: Math.floor(Date.now() / 1000),
              model:
                typeof payload.model === "string"
                  ? payload.model
                  : "clawdbot-agent",
              choices: [
                {
                  index: 0,
                  delta: { content },
                  finish_reason: null,
                },
              ],
            });
          }

          if (!closed) {
            closed = true;
            unsubscribe();
            writeDone(res);
            res.end();
          }
        } catch (err) {
          if (closed) return;
          closed = true;
          unsubscribe();
          writeSse(res, {
            id: runId,
            object: "chat.completion.chunk",
            created: Math.floor(Date.now() / 1000),
            model:
              typeof payload.model === "string"
                ? payload.model
                : "clawdbot-agent",
            choices: [
              {
                index: 0,
                delta: { content: `Error: ${String(err)}` },
                finish_reason: "stop",
              },
            ],
          });
          writeDone(res);
          res.end();
        }
      })();

      return true;
    }

    try {
      const result = await agentCommand(
        {
          message: agentInputs.message,
          extraSystemPrompt: agentInputs.extraSystemPrompt,
          runId,
          deliver: false,
          provider: "whatsapp",
          bestEffortDeliver: false,
        },
        defaultRuntime,
        deps,
      );

      const payloads = (
        result as { payloads?: Array<{ text?: string }> } | null
      )?.payloads;
      const content =
        Array.isArray(payloads) && payloads.length > 0
          ? payloads
              .map((p) => (typeof p.text === "string" ? p.text : ""))
              .filter(Boolean)
              .join("\n\n")
          : "No response from Clawdbot.";

      const response = {
        id: runId,
        object: "chat.completion",
        created: Math.floor(Date.now() / 1000),
        model:
          typeof payload.model === "string" ? payload.model : "clawdbot-agent",
        choices: [
          {
            index: 0,
            message: {
              role: "assistant",
              content: content,
            },
            finish_reason: "stop",
          },
        ],
        usage: {
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0,
        },
      };

      sendJson(res, 200, response);
    } catch (err) {
      sendJson(res, 500, {
        error: { message: String(err), type: "api_error" },
      });
    }
    return true;
  }

  return false;
}
