import { HttpError } from "./http";

type Box = { type: string; start: number; data: number; end: number };
function invalid(): never { throw new Error("Invalid AAC recording"); }

// A bounded ISO-BMFF parser for native AAC voice recordings. This validates media
// structure/sample bounds, not AAC decoding; AVPlayer previews the recording on iOS.
export function inspectAudio(bytes: Buffer, mime: string): { duration_ms: number } {
  try {
    if (mime !== "audio/mp4" || bytes.length < 64 || bytes.length > 4 * 1024 * 1024) invalid();
    let budget = 10000;
    const boxes = (start: number, end: number): Box[] => {
      const found: Box[] = [];
      while (start < end) {
        if (--budget < 0 || end - start < 8) invalid();
        let size = bytes.readUInt32BE(start), header = 8;
        if (size === 1) {
          if (end - start < 16) invalid();
          const wide = bytes.readBigUInt64BE(start + 8);
          if (wide > BigInt(bytes.length)) invalid();
          size = Number(wide); header = 16;
        } else if (size === 0) size = end - start;
        if (size < header || size > end - start) invalid();
        found.push({ type: bytes.toString("ascii", start + 4, start + 8), start, data: start + header, end: start + size });
        start += size;
      }
      return found;
    };
    const one = (list: Box[], type: string) => {
      const found = list.filter(box => box.type === type);
      if (found.length !== 1) invalid();
      return found[0];
    };
    const u32 = (box: Box, offset: number) => {
      if (box.data + offset + 4 > box.end) invalid();
      return bytes.readUInt32BE(box.data + offset);
    };
    const duration = (box: Box) => {
      const version = bytes[box.data];
      if (![0, 1].includes(version)) invalid();
      const scale = u32(box, version === 1 ? 20 : 12);
      const offset = box.data + (version === 1 ? 24 : 16);
      if (offset + (version === 1 ? 8 : 4) > box.end || !scale) invalid();
      const ticks = version === 1 ? Number(bytes.readBigUInt64BE(offset)) : bytes.readUInt32BE(offset);
      const ms = ticks / scale * 1000;
      if (!Number.isFinite(ms) || ms <= 0 || ms > 60000) invalid();
      return { scale, ticks, ms };
    };
    const top = boxes(0, bytes.length);
    const ftyp = one(top, "ftyp");
    if (ftyp.end - ftyp.data < 8 || (ftyp.end - ftyp.data) % 4) invalid();
    const brands = [bytes.toString("ascii", ftyp.data, ftyp.data + 4)];
    for (let at = ftyp.data + 8; at < ftyp.end; at += 4) brands.push(bytes.toString("ascii", at, at + 4));
    if (!brands.some(brand => ["M4A ", "isom", "mp41", "mp42"].includes(brand))) invalid();
    const media = top.filter(box => box.type === "mdat" && box.end > box.data);
    if (!media.length || top.some(box => box.type === "moof")) invalid();
    const movie = boxes(one(top, "moov").data, one(top, "moov").end);
    const movieDuration = duration(one(movie, "mvhd"));
    const track = one(movie, "trak");
    const mdia = one(boxes(track.data, track.end), "mdia");
    const trackMedia = boxes(mdia.data, mdia.end);
    const handler = one(trackMedia, "hdlr");
    if (handler.end - handler.data < 12 || bytes.toString("ascii", handler.data + 8, handler.data + 12) !== "soun") invalid();
    const trackDuration = duration(one(trackMedia, "mdhd"));
    const minf = one(trackMedia, "minf");
    const stbl = one(boxes(minf.data, minf.end), "stbl");
    const tables = boxes(stbl.data, stbl.end);
    const descriptions = one(tables, "stsd");
    if (u32(descriptions, 4) !== 1) invalid();
    const sound = one(boxes(descriptions.data + 8, descriptions.end), "mp4a");
    if (sound.end - sound.data < 28 || bytes.readUInt16BE(sound.data + 8) !== 0) invalid();
    const channels = bytes.readUInt16BE(sound.data + 16);
    if (![1, 2].includes(channels)) invalid();
    const esds = one(boxes(sound.data + 28, sound.end), "esds");
    let aac = false, config = false;
    const descriptors = (start: number, end: number, depth = 0) => {
      if (depth > 4) invalid();
      while (start < end) {
        if (--budget < 0) invalid();
        const tag = bytes[start++];
        let size = 0, count = 0, part: number;
        do { if (start >= end || ++count > 4) invalid(); part = bytes[start++]; size = size * 128 + (part & 127); } while (part & 128);
        const finish = start + size;
        if (finish > end) invalid();
        if (tag === 3) {
          if (size < 3) invalid();
          const flags = bytes[start + 2]; let nested = start + 3;
          if (flags & 128) nested += 2;
          if (flags & 64) { if (nested >= finish) invalid(); nested += 1 + bytes[nested]; }
          if (flags & 32) nested += 2;
          if (nested > finish) invalid();
          descriptors(nested, finish, depth + 1);
        } else if (tag === 4) {
          if (size < 13 || bytes[start] !== 0x40 || (bytes[start + 1] >> 2) !== 5) invalid();
          aac = true; descriptors(start + 13, finish, depth + 1);
        } else if (tag === 5) {
          if (size < 2 || (bytes[start] >> 3) !== 2) invalid();
          const rate = ((bytes[start] & 7) << 1) | (bytes[start + 1] >> 7);
          const configChannels = (bytes[start + 1] >> 3) & 15;
          // Apple's AAC mono encoder can retain the historical stereo channel
          // count in mp4a; the codec's AudioSpecificConfig is authoritative.
          if (rate > 12 || ![1, 2].includes(configChannels)) invalid();
          config = true;
        }
        start = finish;
      }
    };
    descriptors(esds.data + 4, esds.end);
    if (!aac || !config) invalid();
    const sizes = one(tables, "stsz"), fixedSize = u32(sizes, 4), sampleCount = u32(sizes, 8);
    if (!sampleCount || sampleCount > 10000 || (fixedSize === 0 && sizes.end - sizes.data !== 12 + sampleCount * 4)) invalid();
    const sampleSizes = Array.from({ length: sampleCount }, (_, index) => fixedSize || u32(sizes, 12 + index * 4));
    if (sampleSizes.some(size => size < 1 || size > 65536)) invalid();
    const timing = one(tables, "stts"), timingCount = u32(timing, 4);
    if (!timingCount || timingCount > 10000 || timing.end - timing.data !== 8 + timingCount * 8) invalid();
    let timedSamples = 0, ticks = 0;
    for (let index = 0; index < timingCount; index++) {
      const count = u32(timing, 8 + index * 8), delta = u32(timing, 12 + index * 8);
      if (!count || !delta) invalid();
      timedSamples += count; ticks += count * delta;
    }
    const sampleMs = ticks / trackDuration.scale * 1000;
    if (timedSamples !== sampleCount || !Number.isFinite(sampleMs) || sampleMs <= 0 || sampleMs > 60000
      || Math.abs(ticks - trackDuration.ticks) > 2048) invalid();
    const chunkTable = tables.find(box => box.type === "stco" || box.type === "co64");
    if (!chunkTable || tables.filter(box => ["stco", "co64"].includes(box.type)).length !== 1) invalid();
    const chunkCount = u32(chunkTable, 4), offsetSize = chunkTable.type === "co64" ? 8 : 4;
    if (!chunkCount || chunkCount > sampleCount || chunkTable.end - chunkTable.data !== 8 + chunkCount * offsetSize) invalid();
    const layout = one(tables, "stsc"), layoutCount = u32(layout, 4);
    if (!layoutCount || layoutCount > chunkCount || layout.end - layout.data !== 8 + layoutCount * 12) invalid();
    const layouts = Array.from({ length: layoutCount }, (_, index) => ({ first: u32(layout, 8 + index * 12), count: u32(layout, 12 + index * 12), description: u32(layout, 16 + index * 12) }));
    if (layouts[0].first !== 1 || layouts.some((row, index) => !row.count || row.description !== 1 || row.first > chunkCount || (index > 0 && row.first <= layouts[index - 1].first))) invalid();
    let sample = 0, segment = 0;
    const occupied: { start: number; end: number }[] = [];
    for (let chunk = 1; chunk <= chunkCount; chunk++) {
      if (segment + 1 < layouts.length && layouts[segment + 1].first <= chunk) segment++;
      const count = layouts[segment].count;
      if (sample + count > sampleCount) invalid();
      const rawOffset = chunkTable.data + 8 + (chunk - 1) * offsetSize;
      const offset = offsetSize === 8 ? Number(bytes.readBigUInt64BE(rawOffset)) : bytes.readUInt32BE(rawOffset);
      let length = 0;
      for (let index = 0; index < count; index++) length += sampleSizes[sample++];
      if (!Number.isSafeInteger(offset) || !media.some(box => offset >= box.data && offset + length <= box.end)) invalid();
      occupied.push({ start: offset, end: offset + length });
    }
    if (sample !== sampleCount) invalid();
    occupied.sort((a, b) => a.start - b.start);
    if (occupied.some((row, index) => index > 0 && row.start < occupied[index - 1].end)) invalid();
    return { duration_ms: Math.ceil(Math.max(sampleMs, trackDuration.ms, movieDuration.ms)) };
  } catch { throw new HttpError(400, "This voice recording could not be read. Record up to 60 seconds."); }
}
