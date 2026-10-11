import { readWeb, searchWeb } from "./research";
import { httpUrl } from "./validation";

type Place = { name: string; address: string; website?: string | null };
type Research = { search: typeof searchWeb; read: typeof readWeb };
const reservationHosts = ["opentable.com", "resy.com", "exploretock.com", "sevenrooms.com"];
const normalized = (text: string) => text.normalize("NFKC").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
const genericWords = new Set(["the", "and", "of", "restaurant", "bar", "cafe", "street", "st", "avenue", "ave", "road", "rd"]);

function comparableURL(value: string) {
  const url = new URL(value);
  url.hash = "";
  url.pathname = url.pathname.replace(/\/+$/, "") || "/";
  return url.toString();
}

export function bookingHostAllowed(place: Place, raw: string) {
  const url = new URL(httpUrl.parse(raw));
  const officialHost = place.website ? new URL(httpUrl.parse(place.website)).hostname.replace(/^www\./, "") : null;
  const host = url.hostname.replace(/^www\./, "");
  return host === officialHost || reservationHosts.some(domain => host === domain || host.endsWith(`.${domain}`));
}

export function pageIdentifiesPlace(place: Place, text: string) {
  const words = new Set(normalized(text).split(" "));
  const name = normalized(place.name).split(" ").filter(word => !genericWords.has(word));
  if (!name.length || !name.every(word => words.has(word))) return false;
  // Chain names alone cannot identify a branch. Require the street number and a distinctive street word when available.
  const street = normalized(place.address.split(",")[0] ?? "").split(" ");
  const number = street.find(word => /^\d+[a-z]?$/i.test(word));
  const streetWords = street.filter(word => !/^\d/.test(word) && !genericWords.has(word));
  return !number || (words.has(number) && (!streetWords.length || streetWords.some(word => words.has(word))));
}

export async function verifyBookingLink(place: Place, raw?: string,
  research: Research = { search: searchWeb, read: readWeb }) {
  const requested = raw ? httpUrl.parse(raw) : undefined;
  if (requested && !bookingHostAllowed(place, requested)) throw new Error("Use this venue's official website or a supported reservation platform.");
  const { results } = await research.search(`${place.name} ${place.address} official reservations booking`);
  if (requested && !results.some(source => comparableURL(source.url) === comparableURL(requested))) {
    throw new Error("This booking page was not found in the venue research sources.");
  }
  const candidates = requested ? [requested] : [...new Set(results.map(source => source.url))].filter(url => {
    try { return bookingHostAllowed(place, url); } catch { return false; }
  }).slice(0, 3);
  let failure: unknown;
  for (const url of candidates) {
    try {
      const page = await research.read(url);
      const content = `${page.title} ${page.text}`;
      if (!pageIdentifiesPlace(place, content) || !/\b(?:reservations?|reserve|booking|book)\b|訂位|預訂|预订|預約|予約/i.test(content)) {
        throw new Error("The page does not confirm this venue, branch and booking option. Keep the existing link and ask the user to verify it.");
      }
      return { url, source_url: page.url, title: page.title, checked_at: new Date().toISOString() };
    } catch (error) { failure = error; }
  }
  if (failure) throw failure;
  throw new Error("No accessible booking page was found in the venue's research sources.");
}
