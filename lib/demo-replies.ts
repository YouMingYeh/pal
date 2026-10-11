import { z } from "zod";
import { checked } from "./db";
import { demoLines, promptsForDemo } from "./demo";
import { agentActionInScope, type jobScope, type SourceMessage } from "./job-scope";
import { saveMemberFacts } from "./member-memory";
import { prepareMemberResponse, type ResponseState } from "./member-response";
import { id, parsedPalOutputs } from "./validation";

type Scope = Awaited<ReturnType<typeof jobScope>>;
const registered = z.object({
  kind: z.enum(["chat", "plan"]), generation: id, run_id: id, step: z.number().int().min(1).max(6),
  operator_message_id: id, operator_user_id: id, actor_ids: z.array(id).length(3),
  starts_at: z.string().datetime({ offset: true }),
});
const placeSchema = z.object({ id, group_id: id, name: z.string().min(1).max(160), status: z.string() });
const planSchema = z.object({ id, group_id: id, title: z.string(), place_id: id, status: z.enum(["draft", "confirmed", "cancelled"]),
  starts_at: z.string().datetime({ offset: true }), created_at: z.string(), updated_at: z.string(), version: z.number().int().positive() });
type Marker = { mockDemo: true; kind: "chat" | "plan"; generation: string; runId: string; step: number; capture?: { targetId: string; planVersion: number } };

export const chatDemoReplies = [
  { body: "👏 You closed yours. The fifty-four-tab ‘filing system’ has declined to comment.", emotion: "hilare" },
  { body: "Pineapple stays. The pizza can handle contrast; apparently this chat cannot.", emotion: "fier" },
  { body: "‘Emotionally five minutes away’ is an ETA with a liberal arts degree.", emotion: "hilare" },
  { body: "Night off. No itinerary, no guilt. You don’t have to turn being tired into another task.", emotion: "attentif" },
  { body: "The bookmarks are thriving. Their owners are in a committed relationship with ‘sometime.’", emotion: "curieux" },
  { body: "Your bookmarks have more plans than you do, and even your ETA needs emotional support.", emotion: "hilare" },
] as const;

/** Scope comes from jobScope; registration and run identity come only from the protected state RPC. */
export function registeredDemoScene(scope: Scope, raw: unknown) {
  const state = raw as ResponseState & { settings?: { is_demo?: boolean; is_direct?: boolean; timezone: string }; demo?: unknown };
  if (!state?.settings?.is_demo || state.settings.is_direct !== false || scope.job.job_kind === "weekly") return null;
  const parsed = registered.safeParse(state.demo);
  if (!parsed.success) return null;
  const demo = parsed.data, step = demo.step - 1;
  if (new Set(demo.actor_ids).size !== 3 || demo.actor_ids.includes(demo.operator_user_id)) return null;
  const operator = scope.batch.find(source => source.id === demo.operator_message_id && source.group_id === scope.job.group_id
    && source.role === "user" && source.sender_id === demo.operator_user_id && source.sender_id === scope.job.requester_id);
  if (!operator || operator.body !== promptsForDemo(demo.kind)[step]) return null;
  const actors = demoLines(step, demo.actor_ids, demo.kind).map(line => {
    const source = scope.batch.find(source => source.group_id === scope.job.group_id && source.role === "user"
      && source.sender_id === line.user_id && source.body === line.body && Date.parse(source.created_at) >= Date.parse(operator.created_at));
    if (!source) throw new Error("Wait for the registered rehearsal cast to finish this scene.");
    return source;
  });
  const marker: Marker = { mockDemo: true, kind: demo.kind, generation: demo.generation, runId: demo.run_id, step };
  return { state, demo, step, operator, actors, marker };
}

async function checkpoint(scope: Scope, marker: Marker) {
  const row = checked(await scope.db.from("agent_jobs").update({ result: JSON.stringify(marker) })
    .eq("id", scope.job.id).eq("attempts", scope.job.attempts).eq("status", "running")
    .eq("lease_until", scope.job.lease_until).select("id").maybeSingle());
  if (!row) throw new Error("Rehearsal job lease is no longer active.");
}

function priorCapture(scope: Scope, marker: Marker) {
  try {
    const previous = JSON.parse(scope.job.result || "null") as Marker | null;
    if (previous?.mockDemo && previous.kind === marker.kind && previous.generation === marker.generation
      && previous.runId === marker.runId && previous.step === marker.step && previous.capture
      && id.safeParse(previous.capture.targetId).success && Number.isSafeInteger(previous.capture.planVersion) && previous.capture.planVersion > 0) return previous.capture;
  } catch { /* Only a trusted matching checkpoint may replay a completed confirmation receipt. */ }
  return undefined;
}

async function capture(scope: Scope, source: SourceMessage, target: z.infer<typeof planSchema>, kind: "plan" | "confirmation", response: Record<string, unknown>) {
  const result = checked(await scope.db.rpc("pal_capture_member_response", {
    p_job_id: scope.job.id, p_job_attempt: scope.job.attempts, p_source_message_id: source.id,
    p_evidence: source.body, p_target_kind: kind, p_target_id: target.id, p_response: response,
  }));
  if (result?.captured !== true) throw new Error("A newer member response takes priority over the rehearsal.");
  const actual = planSchema.parse(result);
  if (actual.id !== target.id || actual.group_id !== scope.job.group_id || actual.status !== "confirmed") throw new Error("Confirmed rehearsal plan required.");
  return actual;
}

export async function mockDemoReply(scope: Scope, raw: unknown, now = Date.now()) {
  const scene = registeredDemoScene(scope, raw);
  if (!scene) return null; // Edited prompts and ordinary rooms continue through the real agent.
  const { state, demo, step, operator, actors, marker } = scene;
  const reply = (body: string, emotion = "fier", entityId?: string) => ({ body, emotion,
    ...(entityId ? { card: { type: "plan", entity_id: entityId } } : {}) });
  if (demo.kind === "chat") return { outputs: parsedPalOutputs({ reply: "", messages: [{ ...chatDemoReplies[step],
    ...(step === 2 ? { reply_to_id: actors[0].id } : {}) }] }), result: marker };
  const start = Date.parse(demo.starts_at);
  if (!Number.isFinite(start) || start <= now) throw new Error("Restart rehearsal with a future Friday.");
  const local = new Intl.DateTimeFormat("en-US", { timeZone: state.settings.timezone, weekday: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(new Date(start));
  if (local.find(part => part.type === "weekday")?.value !== "Fri" || local.find(part => part.type === "hour")?.value !== "19"
    || local.find(part => part.type === "minute")?.value !== "30") throw new Error("Rehearsal requires its actual Friday 7:30 starting time.");
  const places = z.array(placeSchema).parse((raw as { places?: unknown }).places ?? []).filter(place => place.group_id === scope.job.group_id && place.status === "resolved");
  const candidates = places.filter(place => /^delfina$/i.test(place.name.trim()));
  if (candidates.length !== 1) throw new Error("One resolved Delfina saved in this rehearsal is required.");
  const place = candidates[0];
  let messages: ReturnType<typeof reply>[];
  if (step === 0) {
    const expiry = new Date(start + 86400_000).toISOString();
    await saveMemberFacts({ facts: [
      { source_message_id: actors[0].id, evidence: "Vegetarian here", kind: "preference", key: "diet", value: "Vegetarian" },
      { source_message_id: actors[0].id, evidence: "I'm free Friday after seven.", kind: "availability", key: "friday", value: "Free Friday after 7 PM", expires_at: expiry },
      { source_message_id: actors[1].id, evidence: "Pasta would be nice.", kind: "preference", key: "food", value: "Would like pasta" },
      { source_message_id: actors[1].id, evidence: "I finish work at seven in SoMa.", kind: "availability", key: "friday", value: "Finishes work at 7 PM in SoMa", expires_at: expiry },
      { source_message_id: actors[2].id, evidence: "Around $40 before drinks, please.", kind: "preference", key: "budget", value: "Around $40 before drinks" },
      { source_message_id: actors[2].id, evidence: "Friday works.", kind: "availability", key: "friday", value: "Friday works; exact arrival time not stated", expires_at: expiry },
    ] }, scope);
    messages = [reply("Friday after seven, vegetarian-friendly, around $40 before drinks. Actual constraints—look at us becoming a functioning group.", "heureux")];
  } else if (step === 1) {
    messages = [reply("Delfina’s already saved. Menu and prices still need checking; a bookmark isn’t a promise.", "curieux")];
  } else if (step === 2) {
    const saved = planSchema.parse(await agentActionInScope(scope, "plan.create", {
      title: "Delfina dinner", place_id: place.id, starts_at: demo.starts_at,
      ends_at: new Date(start + 7200_000).toISOString(), notes: "Vegetarian menu and budget need checking. Restaurant not booked.",
    }, "draft"));
    if (saved.group_id !== scope.job.group_id || saved.status !== "draft" || saved.place_id !== place.id || Date.parse(saved.starts_at) !== start) throw new Error("Expected saved rehearsal draft.");
    messages = [reply("Delfina, Friday 7:30. Draft saved. Optimism, with paperwork.", "fier", saved.id)];
  } else {
    const plans = z.array(planSchema).parse(state.plans).filter(plan => plan.group_id === scope.job.group_id
      && plan.place_id === place.id && Date.parse(plan.starts_at) === start + 1800_000 && plan.status !== "cancelled");
    if (plans.length !== 1) throw new Error("One current rehearsal dinner at eight is required.");
    let target = plans[0];
    if (step === 3) {
      if (target.status !== "draft") throw new Error("Rehearsal time edit requires a real draft.");
      messages = [reply("Eight it is. Theo’s plot twist has been absorbed.", "surpris", target.id)];
    } else if (step === 4) {
      const previous = priorCapture(scope, marker);
      let response;
      if (target.status === "confirmed" && previous?.targetId === target.id && target.version === previous.planVersion + 1) {
        response = { plan_version: previous.planVersion };
      } else {
        response = prepareMemberResponse({ target_kind: "confirmation", target_id: target.id, source_message_id: operator.id, evidence: operator.body }, scope.batch, state, scope.job.group_id, now).response;
        marker.capture = { targetId: target.id, planVersion: target.version };
        await checkpoint(scope, marker);
      }
      target = await capture(scope, operator, target, "confirmation", response);
      messages = []; // The real confirmation transaction already posts the authoritative RSVP invitation.
    } else {
      const sources = [operator, ...actors].sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at));
      const responses = sources.map(source => ({ source, response: prepareMemberResponse({ target_kind: "plan", target_id: target.id,
        source_message_id: source.id, evidence: source.body, status: "going" }, scope.batch, state, scope.job.group_id, now).response }));
      for (const entry of responses) await capture(scope, entry.source, target, "plan", entry.response);
      messages = [reply("Your RSVPs are in. Friday, 8 PM, Delfina. We’re dangerously organized.", "heureux", target.id)];
    }
  }
  return { outputs: parsedPalOutputs({ reply: "", messages }), result: marker };
}
