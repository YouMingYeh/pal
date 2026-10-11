import assert from "node:assert/strict";
import { test } from "node:test";
import { bookingHostAllowed, pageIdentifiesPlace, verifyBookingLink } from "../lib/booking";
import { parseAgentAction } from "../lib/validation";

const place = { name: "Quiet Table", address: "12 Market Street, San Francisco", website: "https://quiet-table.example" };
const booking = "https://resy.com/cities/sf/quiet-table";
const venueText = "Quiet Table reservations. Visit us at 12 Market Street, San Francisco.";
const research = {
  async search() { return { results: [{ title: "Quiet Table", url: booking, snippet: venueText }] }; },
  async read(url: string) { return { url, title: "Quiet Table reservations", text: venueText }; },
};

test("booking research requires a cited readable page for the actual venue and branch", async () => {
  const verified = await verifyBookingLink(place, booking, research);
  assert.equal(verified.url, booking);
  assert.equal(verified.source_url, booking);
  assert.equal((await verifyBookingLink(place, undefined, research)).url, booking, "One tool can discover and verify the booking page without a preliminary search call.");
  await assert.rejects(verifyBookingLink(place, booking, {
    ...research, async search() { return { results: [] }; },
  }), /not found/);
  await assert.rejects(verifyBookingLink(place, booking, {
    ...research, async read() { return { url: booking, title: "Other restaurant", text: "Book Other Restaurant at 12 Market Street" }; },
  }), /does not confirm/);
  await assert.rejects(verifyBookingLink(place, booking, {
    ...research, async read() { throw new Error("Page unavailable"); },
  }), /Page unavailable/);
  assert.equal(pageIdentifiesPlace(place, "Quiet Table at 88 Market Street"), false, "Same chain at another branch is not verified.");
  await assert.rejects(verifyBookingLink(place, booking, {
    ...research, async read() { return { url: booking, title: "Quiet Table", text: "Quiet Table at 12 Market Street. Privacy policy." }; },
  }), /booking option/);
});

test("booking domains cannot impersonate providers or hide credentials", async () => {
  assert.equal(bookingHostAllowed(place, "https://quiet-table.example/reservations"), true);
  assert.equal(bookingHostAllowed(place, booking), true);
  assert.equal(bookingHostAllowed(place, "https://resy.com.attacker.example/quiet-table"), false);
  assert.equal(bookingHostAllowed(place, "https://attacker.example/resy.com"), false);
  assert.throws(() => bookingHostAllowed(place, "https://secret:token@resy.com/quiet-table"));
  let lookedUp = false;
  await assert.rejects(verifyBookingLink(place, "https://attacker.example/reservation", {
    ...research, async search() { lookedUp = true; return { results: [] }; },
  }), /official website/);
  assert.equal(lookedUp, false, "Unapproved destinations never enter venue research.");
});

test("agent booking-link update cannot change a venue or mark a reservation booked", () => {
  const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  assert.deepEqual(parseAgentAction("place.correct", { id, booking_url: booking }), { id, booking_url: booking });
  assert.throws(() => parseAgentAction("place.correct", { id, booking_url: booking, latitude: 0, longitude: 0 }));
  assert.throws(() => parseAgentAction("place.correct", { id, booking_url: booking, website: "https://attacker.example" }));
  assert.throws(() => parseAgentAction("plan.booking", { id, status: "booked" }), /requires a group member/);
});
