-- Synthetic host: every subprocess and file operation is intercepted; no hardware.
local status = dofile("aula-f75/status.luau")
local ops = dofile("aula-f75/operations.luau")
local function report(id)
    return { schema_version = 1, command = "status", ok = true,
        observed_native_effects = {{id=1,name="fixed_on"},{id=2,name="respire"},{id=18,name="storm"}},
        devices = {{transport="wired",interface_verified=true,protocol_verified=true,keyboard_connected=true,
            model={matches_expected=true},capabilities={brightness=true,lighting_power=true},
            configuration={lighting_mode="solid",active_effect={id=id or 1,name="fixed_on"},brightness=5,color_index=1,color_name="green"}}} }
end
local function review(kind, value)
    local p = { persistent=true,no_op=false,approval_required=true,review_state={configuration_hex=string.rep("00",128),matrix_hex=string.rep("00",384)},
        previous_brightness=5,requested_brightness=value,previous_palette={index=1,name="green"},requested_palette={index=value,name="blue"} }
    return {schema_version=1,command="lighting_"..kind,ok=true,review_ready=true,[kind.."_plan"]=p}
end
local callbacks, values, watchers, files, decoded, calls = {}, {}, {}, {}, {}, {}
local removed = 0
noctalia = {
 state={get=function(k)return values[k]end,set=function(k,v)values[k]=v;if watchers[k]then watchers[k](v)end end,watch=function(k,f)watchers[k]=f end},
 commandExists=function()return true end,
 json={decode=function(raw)return decoded[raw]end},
 runAsync=function(args,cb,timeout) calls[#calls+1]=args; if cb then callbacks[#callbacks+1]=cb end;return true end,
 writeFile=function(p,data)assert(not files[p]);files[p]=data;return true end,
 removeFile=function(p)files[p]=nil;removed=removed+1;return true end,
}
local old = require
require=function(p)if p=="./status.luau"then return status end;assert(p=="./operations.luau");return ops end
dofile("aula-f75/service.luau")
require=old
local function reply(raw,code)
 local cb=table.remove(callbacks,1);assert(cb,"missing callback"); cb({exitCode=code or 0,stdout=raw})
end
local function refresh(r)
 decoded.status=r or report();status.request();reply("status")
end
local function action(a)ops.send(a)end
local function phase()return values[ops.KEY].phase end
local function prepare()
 action({action="prepare",kind="brightness",value=3})
 assert(phase()=="reviewing")
 decoded.review=review("brightness",3);reply("review")
 reply("/run/user/1000");reply("1000");reply("directory:1000:700");reply("/run/user/1000/noctalia-aula.abcdefghij")
 assert(phase()=="ready" and next(files))
end
local function noWrites()
 for _,a in ipairs(calls)do for _,v in ipairs(a)do assert(v~="--apply","write before approval")end end
end
refresh()
local c=values[status.STATE].controls
assert(c.brightness==5 and c.speed==nil and c.palette==1 and #c.effects==4,"backend capabilities/observed picker")
assert(not ops.allowed(values[status.STATE],"brightness",10) and not ops.allowed(values[status.STATE],"brightness",2.5))
assert(not ops.allowed(values[status.STATE],"effect",18) and not ops.allowed(values[status.STATE],"brightness",5))
prepare();noWrites()
action({action="cancel"});assert(phase()=="idle" and not next(files) and removed==1)
prepare()
local before=#calls;action({action="prepare",kind="palette",value=2});status.request();assert(#calls==before,"no overlap while ready")
action({action="apply"});assert(phase()=="applying" and calls[#calls][#calls[#calls]]=="--json")
assert(table.concat(calls[#calls]," "):find("--apply --review /run/user/1000/noctalia-aula.abcdefghij/review.json",1,true))
before=#calls;action({action="apply"});action({action="cancel"});assert(#calls==before,"duplicate apply/cancel cannot interrupt or queue writes")
local cb=table.remove(callbacks,1);cb({timedOut=true});assert(phase()=="refreshing" and values[ops.KEY].error and not next(files))
assert(values[status.STATE].phase=="refreshing","uncertain apply always refreshes")
decoded.status=report();reply("status");assert(values[status.STATE].controls.brightness==5,"never optimistic")
cb({exitCode=0,stdout="late"});assert(values[status.STATE].controls.brightness==5)
-- Cancellation waits for a read-only command before releasing the operation gate.
action({action="prepare",kind="palette",value=2});action({action="cancel"});before=#calls
action({action="prepare",kind="brightness",value=2});assert(#calls==before)
reply("bad");assert(phase()=="idle" and not next(files))
-- Disconnection/review mismatch clears the plan and requires fresh status.
action({action="prepare",kind="brightness",value=2});reply("invalid",1)
decoded.disconnected={schema_version=1,command="status",ok=false,devices={},error={code="device_not_found"}}
reply("disconnected");assert(values[status.STATE].phase=="disconnected" and phase()=="idle")
before=#calls;action({action="apply"});assert(#calls==before)
-- Self-defined ignores retained Storm; unsupported raw nibbles stay hidden.
local r=report(21);local conf=r.devices[1].configuration
conf.lighting_mode="per_key";conf.active_effect.name="self_defined";conf.stored_native_effect_id=18;conf.effect_name="storm";conf.effect_name_scope="saved_selection";conf.speed=nil;conf.color_index=nil
refresh(r);assert(values[status.STATE].active=="Self-defined" and values[status.STATE].controls.speed==nil and values[status.STATE].controls.palette==nil)
-- Off never invents a restoration target, and a failed read-only probe keeps On disabled.
r=report(0);r.devices[1].configuration.active_effect.name="off";r.devices[1].configuration.lighting_mode="off"
refresh(r);reply("no_restore",1);assert(not values[status.STATE].controls.onAvailable)
before=#calls;action({action="prepare",kind="on"});assert(#calls==before)
refresh()
action({action="prepare",kind="brightness",value=3});decoded.noop=review("brightness",3);decoded.noop.brightness_plan.no_op=true
reply("noop");assert(not next(files) and values[status.STATE].phase=="refreshing");reply("status")
action({action="prepare",kind="brightness",value=3});reply("review");reply("/run/user/1000");reply("1000");reply("symbolic link:1000:700")
assert(phase()=="idle" and not next(files), "unsafe runtime metadata must reject storage without writes")
print("AULA operations: review, secure allocation, cancellation, serialization, timeout, mismatch and power gates passed")
