import { ZodError } from "zod";
import { userClient } from "./db";
import { id } from "./validation";

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

export async function authenticated(request: Request) {
  const header = request.headers.get("authorization");
  if (!header?.startsWith("Bearer ")) throw new HttpError(401, "Sign in to continue.");
  const token = header.slice(7);
  const db = userClient(token);
  const { data, error } = await db.auth.getUser(token);
  if (error || !data.user) throw new HttpError(401, "Sign in to continue.");
  return { db, user: data.user };
}

export async function member(request: Request, groupId: string) {
  id.parse(groupId);
  const auth = await authenticated(request);
  const { data, error } = await auth.db.from("group_members").select("group_id")
    .eq("group_id", groupId).eq("user_id", auth.user.id).maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new HttpError(403, "You are not a member of this group.");
  return auth;
}

export async function route(action: () => Promise<Response>) {
  try { return await action(); }
  catch (error) {
    if (error instanceof HttpError) return Response.json({ error: error.message }, { status: error.status });
    if (error instanceof ZodError || error instanceof SyntaxError) {
      return Response.json({ error: "Check your request fields." }, { status: 400 });
    }
    const code = error instanceof Error && "code" in error ? error.code : undefined;
    if (code === "42501") return Response.json({ error: "You cannot make that change." }, { status: 403 });
    if (["22023", "23503", "23514"].includes(String(code))) return Response.json({ error: "Check the fields and current card state." }, { status: 400 });
    if (code === "23505") return Response.json({ error: "That record already exists. Refresh and retry." }, { status: 409 });
    console.error("Pal request failed:", error instanceof Error ? error.message : "Unknown failure");
    return Response.json({ error: "Request could not be completed. Please retry." }, { status: 503 });
  }
}
