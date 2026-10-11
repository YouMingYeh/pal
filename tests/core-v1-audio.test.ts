import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { inspectAudio } from "../lib/audio";
import { HttpError } from "../lib/http";

// Real recordings encoded by ffmpeg, independently probed as AAC/44.1kHz/1s.
// AAC sample-table padding is included in our conservative 1.024s duration.
const voice = readFileSync(new URL("./fixtures/voice-aac.m4a", import.meta.url));
const rejected = (error: unknown) => error instanceof HttpError && error.status === 400;

test("a real AAC recording has bounded duration and media samples", () => {
  const result = inspectAudio(voice, "audio/mp4");
  assert.ok(result.duration_ms >= 1000 && result.duration_ms <= 1050);
});

test("an actual Apple AVFoundation mono recording accepts its AAC codec configuration", () => {
  const apple = readFileSync(new URL("./fixtures/voice-apple-aac.m4a", import.meta.url));
  // AVAudioFile AAC/44.1kHz/mono64kbps, independently ffprobe'd at1.068118s.
  const result = inspectAudio(apple, "audio/mp4");
  assert.ok(result.duration_ms >= 1068 && result.duration_ms <= 1070);
});

test("voice uploads reject video, truncated samples, false duration and broken box sizes", () => {
  assert.throws(() => inspectAudio(readFileSync(new URL("./fixtures/video-aac.mp4", import.meta.url)), "audio/mp4"), rejected);
  assert.throws(() => inspectAudio(voice.subarray(0, voice.length - 30), "audio/mp4"), rejected);
  assert.throws(() => inspectAudio(voice, "image/jpeg"), rejected);
  assert.throws(() => inspectAudio(Buffer.alloc(4 * 1024 * 1024 + 1), "audio/mp4"), rejected);
  const long = Buffer.from(voice), header = long.indexOf(Buffer.from("mdhd"));
  assert.ok(header > 0);
  const scale = long.readUInt32BE(header + 16);
  long.writeUInt32BE(scale * 61, header + 20);
  assert.throws(() => inspectAudio(long, "audio/mp4"), rejected);
  const broken = Buffer.from(voice);
  broken.writeUInt32BE(0xffffffff, 0);
  assert.throws(() => inspectAudio(broken, "audio/mp4"), rejected);
  const outside = Buffer.from(voice), offsets = outside.indexOf(Buffer.from("stco"));
  assert.ok(offsets > 0);
  outside.writeUInt32BE(4, offsets + 12);
  assert.throws(() => inspectAudio(outside, "audio/mp4"), rejected);
});
