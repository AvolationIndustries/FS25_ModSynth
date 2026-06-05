# gen_targets.py — DISCOVERY generator (supersedes gen_hookmap.py).
# Scans all installed zips, finds every Class.method hooked via Utils.*Function,
# keeps curated core + discovered conflicts (2+ hookers, >=1 overwrite, chain<=CAP),
# emits scripts/mm_hookmap_generated.lua with 3 globals:
#   ModMixerTargets    = { "Class.method", ... }              (interceptor watch-list)
#   ModMixerHookMap    = { ["Class.method"] = {mods} }        (scan-elimination)
#   ModMixerTargetInfo = { ["Class.method"] = {name=, cat=} } (UI labels for new ones)
import os, zipfile, re
from collections import defaultdict
mods_dir = r"C:/Users/Administrator/Documents/My Games/FarmingSimulator2025/mods"
OUT = r"B:/Farm Sim Mod Dev/FS25_ModMixer/FS25_ModMixer/scripts/mm_hookmap_generated.lua"
CAP = 8   # max chain length for a DISCOVERED target (bigger = benign registration point)

CURATED = ["WheelPhysics.serverUpdate","WheelPhysics.finalize","WheelPhysics.updatePhysics",
 "WheelPhysics.updateTireFriction","WheelPhysics.updateFriction","WheelPhysics.updateWheelFriction",
 "WheelPhysics.updateContact","WheelsUtil.updateWheelsPhysics","WheelsUtil.updateWheelsPhysicsGroundContact",
 "WheelsUtil.getSmoothedAcceleratorAndBrakePedals","Drivable.updateVehiclePhysics",
 "Motorized.updateConsumers","Motorized.onUpdate","Motorized.getMaxPtoRpm",
 "Motorized.getUseAutomaticGearShifting","Motorized.getUseAutomaticGroupShifting",
 "Vehicle.update","Vehicle.updateTick","Vehicle.onUpdate","Vehicle.load","Vehicle.getSpeedLimit",
 "FSBaseMission.update","FSBaseMission.sendInitialClientState","FSBaseMission.onConnectionFinishedLoading",
 "Sprayer.processSprayerArea","Cutter.onEndWorkAreaProcessing",
 "BunkerSilo.update","BunkerSilo.load","BunkerSilo.loadFromXMLFile",
 "PlayerHUDUpdater.showSplitShapeInfo","PlayerHUDUpdater.showFieldInfo",
 "ConstructionBrush.verifyAccess","Farm.changeBalance","InfoDialog.show",
 "VehicleMaterial.apply","VehicleMaterial.applyToVehicle",
 "PlaceableProductionPoint.onFinalizePlacement","ProductionPoint.load",
 "DensityMapHeightManager.loadMapData","Weather.update",
 "Wearable.updateDamageAmount","Wearable.setOperatingTime","Motorized.getCanMotorRun",
 "Motorized.startMotor","Motorized.updateMotorTemperature","Vehicle.getSellPrice"]

CAT = {"WheelPhysics":"Vehicle Physics","WheelsUtil":"Vehicle Physics","Wheel":"Vehicle Physics","Drivable":"Vehicle Physics",
 "Motorized":"Engine","VehicleMotor":"Engine","PowerConsumer":"Engine","Wearable":"Damage / Wear",
 "Vehicle":"Vehicle Core","Attachable":"Vehicle Core","Enterable":"Vehicle Core","Dashboard":"Vehicle Core","AttacherJoints":"Vehicle Core",
 "FillUnit":"Field Work","Baler":"Field Work","Cutter":"Field Work","Sprayer":"Field Work","Combine":"Field Work",
 "Landscaping":"Terraforming","ConstructionBrush":"Terraforming","ConstructionScreen":"Terraforming","DensityMapHeightManager":"Terraforming",
 "Farm":"Economy","FSCareerMissionInfo":"Economy","StoreManager":"Economy","FillTypeManager":"Economy","FruitTypeManager":"Economy",
 "ShopConfigScreen":"Economy","ShopItemsFrame":"Economy","ProductionPoint":"Economy","PlaceableProductionPoint":"Economy",
 "VehicleMaterial":"Visual","VehicleConfigurationItemColor":"Visual","BaseMaterial":"Visual",
 "FSBaseMission":"Game Core","Mission00":"Game Core","BaseMission":"Game Core","TypeManager":"Game Core",
 "WorkshopScreen":"Vehicle Core","InGameMenuProductionFrame":"Economy",
 "PlayerInputComponent":"UI","InGameMenuSettingsFrame":"UI","InGameMenuProductionFrame":"UI","FocusManager":"UI","BinaryOptionElement":"UI","I18N":"UI",
 "BunkerSilo":"Bunkers","Weather":"Weather","PlayerHUDUpdater":"HUD","HandToolChainsaw":"Forestry","InfoDialog":"UI"}

def pretty(method):
    s = re.sub(r'([a-z0-9])([A-Z])', r'\1 \2', method)
    return s[0].upper()+s[1:] if s else s

ow = re.compile(r"\b([A-Z]\w+)\.(\w+)\s*=\s*Utils\.overwrittenFunction|Utils\.overwrittenFunction\s*\(\s*([A-Z]\w+)\.(\w+)")
ap = re.compile(r"\b([A-Z]\w+)\.(\w+)\s*=\s*Utils\.(?:appended|prepended)Function|Utils\.(?:appended|prepended)Function\s*\(\s*([A-Z]\w+)\.(\w+)")
owm, apm = defaultdict(set), defaultdict(set)
spec = defaultdict(set)  # method -> mods that registerOverwrittenFunction(_, "method", _)
spec_re = re.compile(r"register(?:Overwritten|Appended|Prepended)Function\s*\(\s*\w+\s*,\s*['\"](\w+)['\"]")
zips=[f for f in os.listdir(mods_dir) if f.endswith(".zip")]
for fn in zips:
    mod=fn[:-4]
    try:
        with zipfile.ZipFile(os.path.join(mods_dir,fn)) as z:
            blob=""
            for e in z.namelist():
                if e.endswith(".lua"):
                    try: blob+=z.read(e).decode("utf-8","ignore")
                    except: pass
            if "Function" not in blob: continue
            for m in ow.finditer(blob): owm[(m.group(1) or m.group(3))+"."+(m.group(2) or m.group(4))].add(mod)
            for m in ap.finditer(blob): apm[(m.group(1) or m.group(3))+"."+(m.group(2) or m.group(4))].add(mod)
            for m in spec_re.finditer(blob): spec[m.group(1)].add(mod)
    except: pass

# method uniqueness among the FINAL target set (for safe spec attribution)
def all_hookers(f, method_unique):
    s = owm[f] | apm[f]
    meth = f.split(".",1)[1]
    if method_unique.get(meth):  # add spec-overwriters only when method maps to one target
        s = s | spec.get(meth, set())
    return s

# decide targets: curated (always) + discovered conflicts. A discovered target is a
# function 2+ mods contest (overwrite OR append) that is NOT benign plumbing and NOT a
# per-instance/per-frame "hot" fn. The filter is applied to BOTH overwrite- and
# append-bearing chains.
#
# LESSON (2026-06-05, live log): the old code let OVERWRITE-bearing chains bypass the
# BENIGN filter ("nov>=1 -> always add"). That re-admitted exactly the per-instance
# noise we wanted gone — loadFillUnitFromXML (1851 unknowns), loadInputAttacherJoint
# (1563), showInfo (2933) — functions a mod re-registers once per vehicle instance/type
# at finalizeTypes, flooding the unknown bucket with rows the user can never act on.
# An overwrite on a load/xml/show/info fn is per-instance plumbing, not a user-fixable
# stomp; drop it on both paths. BENIGN now also covers the display/info hot fns.
BENIGN = re.compile(r"save|load|read|write|stream|xml|draw|register|init|finish|"
                    r"complete|persist|^update$|onCreate|delete|"
                    r"show|info|addFillUnitFillLevel", re.I)
discovered, dropped = set(), []
for f in set(owm)|set(apm):
    if f in CURATED: continue
    tot=len(owm[f]|apm[f]); nov=len(owm[f])
    if not (2<=tot<=CAP): continue
    if BENIGN.search(f.split(".",1)[1]):
        dropped.append(f); continue                     # plumbing / per-instance hot fn
    discovered.add(f)                                   # overwrite- OR append-bearing
targets = sorted(set(CURATED)|discovered)
# uniqueness map over the chosen targets
meth_to_targets=defaultdict(list)
for t in targets: meth_to_targets[t.split(".",1)[1]].append(t)
method_unique={m:(len(ts)==1) for m,ts in meth_to_targets.items()}

# build hookmap (exclude self)
hookmap={}
for t in targets:
    ms=sorted(m for m in all_hookers(t, method_unique) if m!="FS25_0_ModMixer")
    if ms: hookmap[t]=ms

L=['-- mm_hookmap_generated.lua  (auto-generated by tools/gen_targets.py — DISCOVERY).',
   '-- ModMixerTargets: interceptor watch-list = curated core + discovered conflicts',
   '-- (2+ hookers, >=1 overwrite, chain<=%d; benign mega append-chains excluded).'%CAP,
   '-- ModMixerHookMap: hookers per target (scan-elimination). ModMixerTargetInfo:',
   '-- auto name+category for discovered targets (curated keep their hand TARGET_INFO).',
   '-- Regenerate (tools/gen_targets.py) whenever the installed mod set changes.','',
   'ModMixerTargets = {']
for t in targets: L.append('    "%s",'%t)
L.append('}')
L.append('')
L.append('ModMixerHookMap = {')
for t in sorted(hookmap): L.append('    ["%s"] = { %s },'%(t, ", ".join('"%s"'%m for m in hookmap[t])))
L.append('}')
L.append('')
L.append('ModMixerTargetInfo = {')
for t in sorted(discovered):
    k=t.split(".")[0]
    L.append('    ["%s"] = { name = "%s", cat = "%s" },'%(t, pretty(t.split(".",1)[1]), CAT.get(k,"Other")))
L.append('}')
open(OUT,"w",encoding="utf-8").write("\n".join(L)+"\n")
print(f"scanned {len(zips)} zips")
print(f"targets total = {len(targets)} (curated {len(CURATED)} + discovered {len(discovered)})")
print(f"hookmap entries = {len(hookmap)}")
print("\nDiscovered targets added:")
for t in sorted(discovered): print(f"  {t}  [{CAT.get(t.split('.')[0],'Other')}]")
print(f"\nDropped {len(dropped)} contested fn(s) as benign/per-instance plumbing:")
for t in sorted(dropped): print(f"  - {t}")
