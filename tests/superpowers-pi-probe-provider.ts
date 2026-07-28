// Scripted Pi provider that records one turn's context and answers nothing useful.
//
// It exists so tests/fm-build-method.test.sh can prove the claim that matters for
// a Pi Build: the `-e <checkout>` flag fm-build-method.sh emits actually activates
// stock Superpowers, rather than merely being accepted by the CLI. Superpowers'
// stock Pi extension injects its `using-superpowers` bootstrap into the turn
// context, so the presence of that text in a real turn is the activation signal.
//
// Every turn is answered locally. No network call is made and no API key is read.
// The recorded context is written to PI_SP_PROBE_OUT.
import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  createAssistantMessageEventStream,
  type AssistantMessage,
  type AssistantMessageEventStream,
  type Context,
  type Model,
  type SimpleStreamOptions,
} from "@earendil-works/pi-ai";

const provider = "sp-probe";
const modelId = "faux-1";

function textOf(message: unknown): string {
  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter(
      (part) =>
        part &&
        typeof part === "object" &&
        (part as { type?: unknown }).type === "text" &&
        typeof (part as { text?: unknown }).text === "string",
    )
    .map((part) => (part as { text: string }).text)
    .join("\n");
}

export default function superpowersPiProbe(pi: ExtensionAPI) {
  function streamSimple(
    model: Model,
    context: Context,
    _options?: SimpleStreamOptions,
  ): AssistantMessageEventStream {
    const stream = createAssistantMessageEventStream();
    const messages = (context as { messages?: unknown }).messages;
    const systemPrompt = String((context as { systemPrompt?: unknown }).systemPrompt ?? "");
    const body = [systemPrompt, ...(Array.isArray(messages) ? messages.map(textOf) : [])].join("\n");
    const out = process.env.PI_SP_PROBE_OUT;
    if (out) writeFileSync(out, body);

    const text = "probe-ok";
    const message: AssistantMessage = {
      role: "assistant",
      content: [{ type: "text" as const, text }],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason: "stop",
      timestamp: Date.now(),
    };

    void (async () => {
      stream.push({ type: "start", partial: { ...message, content: [] } });
      stream.push({ type: "text_start", contentIndex: 0, partial: message });
      stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial: message });
      stream.push({ type: "text_end", contentIndex: 0, content: text, partial: message });
      stream.push({ type: "done", reason: "stop", message });
      stream.end(message);
    })();

    return stream;
  }

  pi.registerProvider(provider, {
    baseUrl: "http://localhost:0",
    apiKey: "test-only",
    api: provider,
    models: [
      {
        id: modelId,
        name: "Superpowers Pi activation probe",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 8192,
        maxTokens: 1024,
      },
    ],
    streamSimple,
  });
}
