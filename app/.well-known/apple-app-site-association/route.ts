export function GET() {
  return Response.json({ applinks: { apps: [], details: [{ appID: "6GAAMYMS72.com.pal.spike", paths: ["/join", "/join/*", "/invite"] }] } }, {
    headers: { "Cache-Control": "public, max-age=3600" },
  });
}
