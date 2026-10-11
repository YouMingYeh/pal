import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { createClient } from "@supabase/supabase-js";
import { admin, checked, env } from "../lib/db";
import { promptsForDemo } from "../lib/demo";
const origin=process.argv[2]; assert.ok(origin,"Supply the deployed origin.");
const kind=process.argv[3]??'plan';assert.ok(kind==='plan'||kind==='chat','Use plan or chat.');
const prompts=promptsForDemo(kind);
const db=admin(), real=JSON.parse(await readFile('.secrets/demo-room.json','utf8')) as {group_id:string;actors:string[]};
let userID:string|undefined, groupID:string|undefined;
let token:string;
async function api(path:string,method="GET",data?:unknown){
 const result=await fetch(origin+path,{method,headers:{authorization:`Bearer ${token}`,"content-type":"application/json"},body:data===undefined?undefined:JSON.stringify(data),signal:AbortSignal.timeout(30000)});
 const body=await result.json();assert.ok(result.ok,`${path} failed ${result.status}: ${body.error??""}`); return body;
}
try{
 const email=`controlled-demo-${randomUUID()}@pal-demo.example`, password=randomUUID()+randomUUID();
 const created=await db.auth.admin.createUser({email,password,email_confirm:true});assert.ifError(created.error);assert.ok(created.data.user);userID=created.data.user.id;
 const client=createClient(env("SUPABASE_URL"),env("SUPABASE_PUBLISHABLE_KEY"),{auth:{persistSession:false,autoRefreshToken:false}});
 const login=await client.auth.signInWithPassword({email,password});assert.ifError(login.error);assert.ok(login.data.session);token=login.data.session.access_token;
 checked(await db.from('profiles').update({display_name:'Presenter'}).eq('user_id',userID));
 const made=await api('/api/groups','POST',{name:`Controlled Demo acceptance ${kind}`,client_id:randomUUID()});groupID=made.group.id;assert.ok(groupID);
 checked(await db.from('groups').update({is_demo:true,proactive_suggestions:false}).eq('id',groupID));
 checked(await db.from('group_members').insert(real.actors.map(user_id=>({group_id:groupID,user_id}))));
 const originals=checked(await db.from('places').select('*').eq('group_id',real.group_id));assert.ok(originals?.length);
 const placeIDs:string[]=[];
 for(const original of kind==='plan'?originals:[]){const {id:_id,group_id:_g,created_at:_c,updated_at:_u,...facts}=original;const id=randomUUID();placeIDs.push(id);checked(await db.from('places').insert({...facts,id,group_id:groupID,created_by:userID}));}
 checked(await db.rpc('pal_demo_register',{p_group_id:groupID,p_actor_ids:real.actors,p_place_ids:placeIDs,p_kind:kind}));
 await api(`/api/groups/${groupID}/demo`,'POST',{action:'reset'});
 for(let step=0;step<6;step++){
  const before=await api(`/api/groups/${groupID}/state`);assert.equal(before.demo.step,step);assert.equal(before.demo.status,'ready');assert.equal(before.demo.next_prompt,prompts[step]);
  const payload={action:'next',step,generation:before.demo.generation,client_id:randomUUID(),body:before.demo.next_prompt};
  const started=Date.now();const accepted=await api(`/api/groups/${groupID}/demo`,'POST',payload);assert.equal(accepted.message.body,payload.body);
  // A transport retry must not create another human message or scripted actor sequence.
  const replay=await api(`/api/groups/${groupID}/demo`,'POST',payload);assert.equal(replay.message.id,accepted.message.id);
  let state=before;
  while(Date.now()-started<240000){
   state=await api(`/api/groups/${groupID}/state`);
   assert.notEqual(state.demo.status,'failed','The real Pal turn failed.');
   if(state.demo.step===step+1&&state.demo.status==='ready')break;
   await sleep(800);
  }
  assert.equal(state.demo.status,'ready',`Scene ${step+1} timed out`);
  const jobs=checked(await db.from('agent_jobs').select('id,status,result,coalesced_into').eq('message_id',accepted.message.id).single());assert.ok(jobs);
  const job=jobs.coalesced_into?checked(await db.from('agent_jobs').select('*').eq('id',jobs.coalesced_into).single()):jobs;assert.ok(job);assert.equal(job.status,'completed');assert.equal(JSON.parse(job.result).mockDemo,true,'Registered scenes use the bounded mock handler.');
  const replies=checked(await db.from('messages').select('id,body').eq('group_id',groupID).like('source_key',`job:${job.id}%`))??[];
  console.log(`Scene ${step+1}: ${Date.now()-started}ms, actual Pal bubbles ${replies.length}, plans ${state.plans.length}.`);
  if(kind==='chat')assert.equal(state.plans.length,0,'Casual banter creates no planning task.');
  if(kind==='plan'&&step===2)assert.ok(state.plans.some((p:{status:string;starts_at:string})=>p.status==='draft'&&Date.parse(p.starts_at)===Date.parse(state.demo.starts_at)),'The handler creates a matching persisted draft.');
  if(kind==='plan'&&step===3)assert.ok(state.plans.some((p:{status:string;starts_at:string})=>p.status==='draft'&&Date.parse(p.starts_at)===Date.parse(state.demo.starts_at)+1800000),'The approved move updates the draft to eight.');
  if(kind==='plan'&&step===4)assert.ok(state.plans.some((p:{status:string})=>p.status==='confirmed'),'Actual source-grounded confirmation succeeds.');
  if(kind==='plan'&&step===5){
   const plan=state.plans.find((p:{status:string})=>p.status==='confirmed');assert.ok(plan);
   for(const attendeeID of [userID,...real.actors])assert.ok(plan.attendees.some((a:{user_id:string;status:string})=>a.user_id===attendeeID&&a.status==='going'),'Each attendee owns a real source-grounded RSVP after confirmation.');
  }
 }
 const complete=await api(`/api/groups/${groupID}/state`);assert.equal(complete.demo.step,6);assert.equal(complete.demo.next_prompt,null);
 const prior=complete.demo.generation;
 await api(`/api/groups/${groupID}/demo`,'POST',{action:'reset'});const clean=await api(`/api/groups/${groupID}/state`);assert.equal(clean.demo.step,0);assert.notEqual(clean.demo.generation,prior);assert.equal(clean.plans.length,0);
 console.log(`ALL GREEN: ${kind} six controlled exchanges used short mock dialogue with guarded persisted state, replay was idempotent, restart isolated.`);
}catch(error){
 // Keep isolated acceptance evidence private before its disposable room is removed.
 if(groupID){
  const [messages,jobs,state]=await Promise.all([
   db.from('messages').select('id,role,body,source_key,created_at').eq('group_id',groupID).order('created_at'),
   db.from('agent_jobs').select('id,message_id,status,result,last_error,coalesced_into').eq('group_id',groupID),
   api(`/api/groups/${groupID}/state`).catch(()=>null),
  ]);
  await writeFile('.secrets/demo-acceptance-failure.json',JSON.stringify({messages:messages.data,jobs:jobs.data,state},null,2),{mode:0o600});
 }
 throw error;
}finally{
 if(groupID)checked(await db.from('groups').delete().eq('id',groupID));
 if(userID)assert.ifError((await db.auth.admin.deleteUser(userID)).error);
}
