# Virtual Cargo POC

Adds virtual cargo capacity to vehicles without native jbeam cargo slots, so PlanEx can use them for deliveries with realistic weight simulation.

## How It Works

1. **JSON config** (`bcm_virtualCargo.json`) defines which models get virtual cargo
2. **GeLua module** (`bcm/virtualCargo.lua`) detects vehicle spawns, sends injection commands
3. **VLua extension** (`bcmVirtualCargo.lua`) modifies `v.data` to inject `cargoStorage` and tag existing vehicle nodes for weight distribution
4. **Vanilla cargo system** (`interactCargoContainers`) treats the vehicle as if it has native cargo — PlanEx is completely unaware

## Files

| File | Purpose |
|------|---------|
| `gameplay/bcm_virtualCargo.json` | Config: models, capacity, offsets |
| `lua/ge/extensions/bcm/virtualCargo.lua` | GeLua orchestrator + console commands |
| `lua/vehicle/extensions/bcmVirtualCargo.lua` | VLua injector: v.data modification + node tagging |

## JSON Config Format

```json
{
  "reziavan": {
    "capacity": 128,
    "cargoTypes": ["parcel"],
    "name": "Trunk Storage",
    "nodeCount": 4,
    "yOffset": 0.0
  },
  "BMW_E34": {
    "capacity": 96,
    "cargoTypes": ["parcel"],
    "name": "Trunk Storage",
    "nodeCount": 4,
    "yOffset": 0.0,
    "configs": ["M5touringbis", "525i_early_m"]
  }
}
```

| Field | Description |
|-------|-------------|
| `capacity` | Number of parcel slots |
| `cargoTypes` | Accepted cargo types (`"parcel"`, `"fluid"`, `"dryBulk"`) |
| `name` | Display name for the cargo container |
| `nodeCount` | How many vehicle nodes to tag for weight (more = smoother) |
| `yOffset` | Meters offset from default cargo zone (+ = rearward, - = forward) |
| `configs` | Optional whitelist of config names. If omitted, all configs apply |

## Console Commands

### Status & Debug

```lua
bcm_virtualCargo.status()     -- Show injection state, tagged nodes, positions
bcm_virtualCargo.nodes()      -- List ALL candidate nodes near cargo zone (with wheel positions)
bcm_virtualCargo.reload()     -- Reload JSON config from disk (gelua only, respawn vehicle for vlua)
```

### Manual Injection

```lua
bcm_virtualCargo.inject()     -- Force inject on current player vehicle
bcm_virtualCargo.shift(0.5)   -- Move cargo zone 0.5m rearward and re-inject (instant, no respawn)
bcm_virtualCargo.shift(-0.3)  -- Move cargo zone 0.3m forward
```

### Simulate Cargo Weight (without PlanEx)

Load 900kg of cargo:
```lua
be:getPlayerVehicle(0):queueLuaCommand('extensions.gameplayInterfaceModules_interactCargoContainers.moduleActions.setCargoContainers({{[99900]={containerId=99900, volume=900, density=1}}, "updateAll"})')
```

Unload all cargo:
```lua
be:getPlayerVehicle(0):queueLuaCommand('extensions.gameplayInterfaceModules_interactCargoContainers.moduleActions.setCargoContainers({{[99900]={containerId=99900, volume=0, density=1}}, "updateAll"})')
```

### Get Vehicle Model Name (for adding to JSON)

```lua
print(be:getPlayerVehicle(0):getJBeamFilename())
```

### Get Vehicle Config Name (for configs whitelist)

```lua
local vd = core_vehicle_manager.getPlayerVehicleData(); print(dumps(vd.config.partConfigFilename))
```

### Reload After Code Changes

GeLua changes (virtualCargo.lua, JSON):
```lua
extensions.reload("bcm_virtualCargo")
```

VLua changes (bcmVirtualCargo.lua): **respawn the vehicle** (reset with R is not enough).

ListingGenerator changes:
```lua
package.loaded["lua/ge/extensions/bcm/listingGenerator"] = nil; extensions.reload("bcm_marketplaceApp")
```

## How Cargo Zone Is Determined

1. **Direction**: Uses `v.data.refNodes[0].ref` and `.back` to determine which Y direction is rearward (varies by vehicle mod)
2. **Rear axle**: Finds rear wheel group using the detected direction
3. **Default position**: 0.3m behind rear axle
4. **yOffset**: Applied in the rearward direction from the default position
5. **Node selection**: Picks `nodeCount` heavy structural nodes (>2kg) with symmetric mirror-pair balancing

## Weight Application

- Weight is applied via vanilla `nodeWeightFunction` expressions on tagged nodes
- Formula: `baseMass + ($volume / nodeCount)` per node
- Suspension beam tagging is **disabled** (structural beam detection was unreliable)
- The vanilla `interactCargoContainers` module handles temporal smoothing automatically

## Known Limitations

- **No suspension adaptation**: Springs/dampers don't stiffen with load (beam tagging disabled). The car gets heavier but suspension doesn't compensate.
- **Node selection heuristic**: May pick suboptimal nodes on some vehicles. Use `nodes()` and `shift()` to diagnose and adjust.
- **No persistence per-save**: Virtual cargo re-injects on every vehicle spawn from the static JSON config.
- **No UI**: Config is JSON-only, testing is console-only.

## Price Overrides for Vehicles Without Base Value

Some mod vehicles have no `Value` in their jbeam, making them invisible to the marketplace. Use `fixedValue` in `bcm_priceOverrides.json`:

```json
{
  "modId": "q8_andronisk",
  "fallback": {
    "match": ["q8_andronisk"],
    "fixedValue": 72000
  },
  "configs": {
    "q8_249_tdi": { "fixedValue": 65000 },
    "rsq8_600_tfsi": { "fixedValue": 115000 },
    "mansory_800_tfsi": { "fixedValue": 195000, "forceClass": "Sports" }
  }
}
```

`fixedValue` takes priority over `valueMultiplier`. Vehicles with `fixedValue` are automatically injected into the marketplace pool even if vanilla filtered them out.
