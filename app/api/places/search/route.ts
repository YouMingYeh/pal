import { z } from "zod";
import { authenticated, route } from "../../../../lib/http";
import { resolvePlace } from "../../../../lib/maps";

const queryInput = z.object({
  q: z.string().trim().min(1).max(200), lat: z.string().trim().min(1).pipe(z.coerce.number<string>().min(-90).max(90)).optional(),
  lon: z.string().trim().min(1).pipe(z.coerce.number<string>().min(-180).max(180)).optional(),
}).strict().refine(value => (value.lat === undefined) === (value.lon === undefined), "Provide both coordinates.");

export function GET(request: Request) {
  return route(async () => {
    await authenticated(request);
    const query = queryInput.parse(Object.fromEntries(new URL(request.url).searchParams));
    const location = query.lat !== undefined && query.lon !== undefined ? { latitude: query.lat, longitude: query.lon } : undefined;
    return Response.json({ places: await resolvePlace(query.q, location) });
  });
}
