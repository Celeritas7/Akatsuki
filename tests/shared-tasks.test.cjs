const assert = require('node:assert/strict');
const Tasks = require('../js/akatsuki-tasks.js');
(async () => {
 const calls=[]; let fail=false;
 const client={rpc:async(name,args)=>{calls.push({name,args});return fail?{error:new Error('offline')}:{data:'stable-id'};},
 from(table){const filters=[];const q={select(){return q;},eq(k,v){filters.push([k,v]);return q;},async maybeSingle(){calls.push({table,filters});return {data:{id:'stable-id',status:'snoozed'}};}};return q;}};
 const tasks=Tasks(client,'chatak');
 assert.equal(await tasks.register({sourceTaskId:'item-1',title:'Buy soap',type:'buy',taskId:'existing-id'}),'stable-id');
 assert.equal(calls[0].args.p_task_id,'existing-id');assert.equal(calls[0].args.p_source_app,'chatak');
 assert.equal((await tasks.get('item-1')).status,'snoozed');
 assert.deepEqual(calls[1].filters,[['source_app','chatak'],['source_task_id','item-1']]);
 await assert.rejects(()=>tasks.schedule({title:'No identity'}),/Task ID/);
 await tasks.schedule({sourceTaskId:'item-1',title:'Soap',dueAt:'2026-12-01T09:00:00+09:00',requestId:'request-1',expectedId:'occurrence-1'});
 const scheduled=calls.find(c=>c.name==='akatsuki_app_task_save');assert.equal(scheduled.args.p_source_app,'chatak');assert.equal(scheduled.args.p_expected_id,'occurrence-1');
 fail=true;await assert.rejects(()=>tasks.register({sourceTaskId:'item-1',title:'Soap'}),/offline/);
 console.log('PASS shared-task client contract and error propagation');
})().catch(e=>{console.error(e);process.exitCode=1;});
