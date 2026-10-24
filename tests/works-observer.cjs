const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const code=fs.readFileSync(process.argv[2],'utf8');
const origin='https://www.douyin.com';
const endpoint=cursor=>origin+'/aweme/v1/web/aweme/post/?sec_user_id=MS4Test&max_cursor='+cursor;
let delivered=[];let responseBody,originalPromise,lastArgs,originalReads=0,checks=0;
function check(ok,label){assert.ok(ok,label);checks++;process.stdout.write('PASS '+label+'\n');}
class XHR{constructor(){this.listeners=[];}open(method,url){this.method=method;this.raw=url;}send(body){this.sent=body;}addEventListener(name,callback){if(name==='load')this.listeners.push(callback);}finish(body,type=''){this.responseType=type;this.response=body;this.responseText=typeof body==='string'?body:JSON.stringify(body);this.responseURL=new URL(this.raw,origin).href;for(const callback of this.listeners)callback();}}
const window={webkit:{messageHandlers:{memoPosts:{postMessage(entry){delivered.push(entry);}}}},fetch(...args){lastArgs=args;const raw=args[0]?.url||args[0];originalPromise=Promise.resolve({url:new URL(raw,origin).href,text(){originalReads++;return Promise.resolve(responseBody);},clone(){return {text(){return Promise.resolve(responseBody);}};}});return originalPromise;}};
const context=vm.createContext({window,XMLHttpRequest:XHR,URL,location:{href:origin+'/user/MS4Test',origin,hostname:'www.douyin.com',protocol:'https:'}});
vm.runInContext(code,context);const hooked=window.fetch;vm.runInContext(code,context);
const flush=()=>new Promise(resolve=>setImmediate(resolve));
const body=()=>JSON.stringify({status_code:0,aweme_list:[{aweme_id:'7690000000000000001'}],has_more:1,max_cursor:'123'});
(async()=>{
 check(window.fetch===hooked,'observer installation is idempotent');
 responseBody=body();const options={credentials:'include',headers:{'X-Test':'kept'}};const result=window.fetch(endpoint(0),options);check(result===originalPromise&&lastArgs[1]===options,'fetch preserves original promise and request options');await flush();check(window.__memoWorksPages.length===1&&originalReads===0,'response clone captures post data without consuming the page response');
 responseBody=body();await window.fetch(endpoint(0));await flush();check(window.__memoWorksPages.length===1,'same author/cursor captured only once');
 for(const url of [origin+'/aweme/v1/web/user/profile/','https://evil.example/aweme/v1/web/aweme/post/',endpoint(9).replace('https:','http:')]){await window.fetch(url);await flush();}check(window.__memoWorksPages.length===1,'foreign, non-post and insecure responses ignored');
 responseBody=JSON.stringify({status_code:4,aweme_list:[]});await window.fetch(endpoint(1));await flush();responseBody=body();await window.fetch(endpoint(1));await flush();check(window.__memoWorksPages.length===2,'verification error does not poison later valid response');
 const xhr=new XHR();xhr.open('GET',endpoint(2));xhr.send('unchanged');xhr.finish(JSON.parse(body()),'json');check(window.__memoWorksPages.length===3&&xhr.sent==='unchanged','XHR JSON captured without altering send body');
 const text=new XHR();text.open('GET',endpoint(3));text.send(null);text.finish(body());check(window.__memoWorksPages.length===4,'XHR text response captured');
 responseBody=body();await window.fetch(endpoint(4));await flush();check(window.__memoWorksPages.length===4,'in-memory queue bounded to four pages');
 check(window.__memoWorksPages.every(entry=>JSON.parse(entry.body).aweme_list[0].aweme_id==='7690000000000000001'),'post IDs preserved as exact strings');
 check(delivered.length===5&&delivered.every(e=>new URL(e.url).origin===origin),'WK bridge receives only accepted post pages');
 console.log('ALL '+checks+' OBSERVER CHECKS PASSED');
})().catch(error=>{console.error(error);process.exitCode=1;});
