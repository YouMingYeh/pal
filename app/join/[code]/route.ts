import { z } from "zod";

export async function GET(request: Request, { params }: { params: Promise<{ code: string }> }) {
  const { code } = await params;
  const parsed = z.uuid().safeParse(code);
  if (!parsed.success) return new Response("Invalid invite code.", { status: 400 });
  return Response.redirect(new URL(`/join?code=${parsed.data}`, request.url));
}
