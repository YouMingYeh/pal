import assert from "node:assert/strict";
import { test } from "node:test";
import { demoLines, demoPrompts, demoRequest, chatDemoPrompts, promptsForDemo } from "../lib/demo";
import { palPersonality } from "../agent/personality";
const ids = ["d0100000-0000-4000-8000-000000000002","d0100000-0000-4000-8000-000000000003","d0100000-0000-4000-8000-000000000004"];
test("six controlled scenes contain only registered mock speakers",()=>{
 assert.equal(demoPrompts.length,6);
 for(let step=0;step<6;step++) for(const line of demoLines(step,ids)) {
  assert.ok(ids.includes(line.user_id)); assert.ok(line.body.length<=1000); assert.ok(!('role' in line));
 }
 assert.throws(()=>demoLines(6,ids)); assert.throws(()=>demoLines(0,[ids[0]]));
 assert.ok(demoPrompts.every(prompt=>!/book|reservation/i.test(prompt)),"The dinner rehearsal schedules an outing, not a reservation.");
 assert.ok(demoLines(4,ids).every(line=>!line.body.startsWith("I'm going")),"Attendance follows actual confirmation, never precedes it.");
 assert.ok(demoLines(5,ids).every(line=>line.body.startsWith("I'm going")));
});
test("casual room uses distinct short messages without creating a draft prerequisite",()=>{
 assert.equal(chatDemoPrompts.length,6);assert.equal(promptsForDemo('chat'),chatDemoPrompts);assert.equal(promptsForDemo('plan'),demoPrompts);
 for(let step=0;step<6;step++)for(const line of demoLines(step,ids,'chat'))assert.ok(ids.includes(line.user_id));
 assert.match(chatDemoPrompts[3],/don't have the energy/);assert.ok(!demoLines(3,ids,'chat').some(line=>/eight|Delfina/.test(line.body)));
});
test("rehearsal controls reject arbitrary actor bodies, identities and reset fields",()=>{
 const request={action:"next",step:0,generation:ids[0],client_id:ids[1],body:demoPrompts[0]};
 const parsed = demoRequest.parse(request); assert.equal(parsed.action,"next"); if (parsed.action === "next") assert.equal(parsed.step,0);
 for(const raw of [{...request,step:6},{...request,generation:"bad"},{...request,lines:[]},{action:"reset",group_id:ids[0]}]) assert.throws(()=>demoRequest.parse(raw));
 assert.deepEqual(demoRequest.parse({action:"reset"}),{action:"reset"});
});
test("Pal's everyday voice can stand alone and preserves actual memory and boundaries",()=>{
 for(const phrase of ["does not always need", "specific to this conversation", "leave room", "never invent", "Private conversations remain private", "Do not try to do all three"]) assert.ok(palPersonality.includes(phrase));
});
