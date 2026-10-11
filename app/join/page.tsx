import { z } from "zod";

export default async function Join({ searchParams }: { searchParams: Promise<{ code?: string }> }) {
  const { code } = await searchParams;
  const parsed = z.uuid().safeParse(code);
  if (!parsed.success) return <main><h1>Pal</h1><p>This invite link is incomplete.</p></main>;
  return <main style={{ fontFamily: "system-ui", maxWidth: 480, margin: "64px auto", padding: 24 }}>
    <h1>Join group</h1>
    <p><a href={`pal://join?code=${parsed.data}`}>Open in Pal</a></p>
    <p>If the app is not installed yet, keep this invite code:</p>
    <p style={{ overflowWrap: "anywhere" }}><code>{parsed.data}</code></p>
  </main>;
}
