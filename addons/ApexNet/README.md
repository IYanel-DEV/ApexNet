# ApexNet — NetSyncExpress

**Zero-code Client-Side Prediction & Server Reconciliation for Godot 4**

Stop watching your multiplayer characters teleport and rubber-band. ApexNet gives your `CharacterBody3D` players instant client-side prediction, server reconciliation, snapshot interpolation, and a visual debugger — all as a single drop-in node. No inheritance, no interface contracts, no boilerplate. Just plug it in, implement two methods, and your players move like butter at 200ms ping.

---

## Quick Installation

1. Copy the `addons/ApexNet/` folder into your project's `addons/` directory.
2. Open **Project > Project Settings > Plugins** and enable **ApexNet**.
3. That's it. The addon is active globally with zero configuration.

---

## 10-Second Setup

### Step 1 — Add the Node

Drag a **NetworkedMovementComponent** node into your `CharacterBody3D` scene as a child:

```
Player (CharacterBody3D)
 └── NetworkedMovementComponent
```

### Step 2 — Implement Two Methods on Your Player Script

```gdscript
class_name Player
extends CharacterBody3D

# Called by the component to sample the current frame's input.
# Return an InputSnapshot with your movement vector, camera angles,
# and any action flags (jump, sprint, etc.).
func get_input_snapshot(tick: int) -> InputSnapshot:
    var snap := InputSnapshot.new()
    snap.tick = tick
    snap.input_vector = Input.get_vector("left", "right", "forward", "back")
    snap.camera_yaw = rotation.y
    snap.actions["jump"] = Input.is_action_just_pressed("jump")
    return snap

# Called by the component to apply a sampled snapshot to this player.
# Handle movement, gravity, jumping — everything that affects physics.
func apply_movement(snap: InputSnapshot, delta: float) -> void:
    # Your existing movement code here, reading from the snapshot.
    # The component calls this for prediction, server replay, and
    # reconciliation — so keep it deterministic and snapshot-driven.
    pass
```

### Step 3 — Point the Component (Optional)

The component finds `get_input_snapshot` and `apply_movement` on its `owner` automatically. No wiring needed as long as your player script has those two methods.

### Step 4 — Enable the Visual Debugger

Select the `NetworkedMovementComponent` in the Inspector and check **Enable Visual Debugger**. A translucent blue ghost will appear, showing the server's authoritative position in real-time so you can see exactly how well your reconciliation is performing.

---

## Features

### Client-Side Prediction

Your local player moves instantly on input — no waiting for the server. The component samples your input, applies it locally, and stores the predicted state in a ring buffer for later reconciliation.

### Server Reconciliation

When the server's authoritative state arrives, the component compares it against your prediction. If the error is:

- **< 0.1m** — A gentle lerp absorbs the jitter silently.
- **0.1m – 5m** — A hard rewind snaps to the server state and replays all pending inputs to fast-forward back to the present.
- **> 5m** — An instant teleport (handles respawns and teleports).

### Snapshot Interpolation

Non-owning clients see remote players glide smoothly between server states using a 6-tick interpolation delay with `lerp` for position and `lerp_angle` for rotation.

### Visual Debugger Ghost

A translucent blue (`Color(0.2, 0.6, 1.0, 0.3)`) duplicate of your player's mesh that always renders at the server's raw authoritative position. The gap between the ghost and your player mesh is your real-time reconciliation error visualization. Toggle it in the Inspector with the `enable_visual_debugger` export.

### Built-in Network Latency Simulator

Set `simulated_latency_ms` on the `GameManager` autoload (e.g. `200`) to inject artificial delay into all outbound RPCs. Test your reconciliation, interpolation, and ghost behavior under realistic lag conditions without touching your network.

### Kinetic Dash Mechanic

A demo `dash` action (C key) that applies a one-frame 22 m/s velocity burst with a 0.8s cooldown. Fully captured by the prediction/reconciliation loop — a showcase of how custom mechanics integrate cleanly.

---

## File Architecture

```
addons/ApexNet/
├── plugin.cfg                          # Godot plugin manifest
├── ApexNet.gd                          # Plugin entry point
└── NetSyncExpress/
    ├── NetworkedMovementComponent.gd   # Core: prediction, reconciliation, interpolation
    ├── NetSyncRingBuffer.gd            # Fixed-capacity ring buffer for tick-indexed data
    ├── StateSnapshot.gd                # Serializable position/rotation/velocity snapshot
    ├── InputSnapshot.gd                # Serializable input snapshot with action flags
    ├── VisualDebuggerGhost.gd          # Translucent ghost mesh controller
    └── VisualDebuggerGhost.tscn        # Ghost scene (Node3D + mesh instance)
```

---

## API Reference

### NetworkedMovementComponent

| Export | Type | Default | Description |
|---|---|---|---|
| `enable_visual_debugger` | `bool` | `false` | Spawns a translucent ghost showing server state |

**Constants:**

| Name | Value | Purpose |
|---|---|---|
| `BUFFER_SIZE` | `128` | Ring buffer capacity for states and inputs |
| `RECONCILIATION_THRESHOLD` | `0.1` | Meters — below this, soft lerp correction |
| `TELEPORT_THRESHOLD` | `5.0` | Meters — above this, instant snap |
| `INTERPOLATION_DELAY_TICKS` | `6` | Physics ticks of interpolation delay (~100ms) |

### InputSnapshot

| Field | Type | Description |
|---|---|---|
| `tick` | `int` | Frame number |
| `input_vector` | `Vector2` | WASD / stick input |
| `camera_yaw` | `float` | Horizontal look angle |
| `camera_pitch` | `float` | Vertical look angle |
| `actions` | `Dictionary` | Action flags (jump, sprint, dash, etc.) |

### StateSnapshot

| Field | Type | Description |
|---|---|---|
| `tick` | `int` | Frame number |
| `position` | `Vector3` | World position |
| `rotation` | `Vector3` | Euler rotation |
| `velocity` | `Vector3` | Physics velocity |

### NetSyncRingBuffer

| Method | Returns | Description |
|---|---|---|
| `push(item)` | `void` | Add item to buffer |
| `get_at(idx)` | `Variant` | Get item by logical index |
| `latest()` | `Variant` | Most recent item |
| `oldest()` | `Variant` | Oldest retained item |
| `find_tick(tick)` | `int` | Find logical index of item with matching tick (-1 if missing) |
| `get_count()` | `int` | Current item count |
| `get_capacity()` | `int` | Max capacity |

---

## Requirements

- **Godot 4.4+** (tested with Jolt Physics and D3D12 renderer)
- Any multiplayer peer (ENet, WebSocket, etc.) — the addon is transport-agnostic
- Your player must extend `CharacterBody3D` and implement `get_input_snapshot()` + `apply_movement()`

---

## License

MIT
