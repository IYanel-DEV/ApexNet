# ApexNet NetworkedMovementComponent — Setup Guide

Drop `NetworkedMovementComponent` as a child of any `CharacterBody3D` (or `RigidBody3D`, `Node3D`) to add multiplayer prediction, reconciliation, and interpolation. The component uses a generic duck-typing contract — your script provides two methods and the component handles the rest.

---

## 1. Required Methods on Your Character Script

### `get_input_snapshot(tick: int) -> InputSnapshot`

Called every physics frame on the **owning client**. Return an `InputSnapshot` with the player's current inputs so the component can transmit them to the server and use them for local prediction.

```gdscript
func get_input_snapshot(tick: int) -> InputSnapshot:
    var snap := InputSnapshot.new()
    snap.tick = tick
    snap.input_vector = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
    snap.camera_yaw = rotation.y
    snap.actions[&"jump"] = Input.is_action_just_pressed(&"jump")
    snap.actions[&"sprint"] = Input.is_action_pressed(&"sprint")
    return snap
```

### `apply_net_movement(snapshot: InputSnapshot, delta: float)`

Called every physics tick on every peer that needs to simulate this character (owning client for prediction, server for authority, replay loop after reconciliation). Read the snapshot and apply movement accordingly.

```gdscript
func apply_net_movement(snap: InputSnapshot, delta: float) -> void:
    var input_dir := snap.input_vector
    if input_dir.length_squared() > 1.0:
        input_dir = input_dir.normalized()

    var wish_dir := Vector3.ZERO
    if input_dir != Vector2.ZERO:
        var forward := -transform.basis.z
        var right := transform.basis.x
        forward.y = 0.0; right.y = 0.0
        forward = forward.normalized()
        right = right.normalized()
        wish_dir = forward * (-input_dir.y) + right * input_dir.x

    var speed := 5.0
    if wish_dir != Vector3.ZERO:
        velocity.x = wish_dir.x * speed
        velocity.z = wish_dir.z * speed
    else:
        velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
        velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)

    velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) * delta

    if is_on_floor() and snap.actions.get(&"jump", false):
        velocity.y = 4.5

    move_and_slide()
```

---

## 2. Optional: State Reset on Hard Snap

When a TELEPORT or REWIND+REPLAY occurs, the component calls `reset_net_state()` on your script if it exists. Use this to clear cooldowns, timers, or any one-frame flags that shouldn't persist across a teleport.

```gdscript
func reset_net_state() -> void:
    _dash_cooldown = 0.0
    _wants_jump = false
```

---

## 3. InputSnapshot Fields

| Field | Type | Purpose |
|---|---|---|
| `tick` | `int` | (set by component) tick counter |
| `input_vector` | `Vector2` | WASD/joystick input (range -1..1) |
| `camera_yaw` | `float` | Horizontal look rotation (radians) |
| `camera_pitch` | `float` | Vertical look rotation (radians) |
| `actions` | `Dictionary` | One-shot & continuous actions (`"jump"`, `"sprint"`, `"dash"`, etc.) |

---

## 4. Inspector Properties

| Property | Default | Description |
|---|---|---|
| `enable_visual_debugger` | `false` | Show ghost + diagnostics panel on owning client |
| `debug_print` | `false` | Log [TICK], [RECV], [RECONCILE], [REPLAY] to console |
| `buffer_size` | `128` | Ring buffer capacity for inputs & states |
| `reconciliation_threshold` | `1.5` | Max error (meters) allowed before hard correction |
| `target_node_path` | (empty) | Optional `NodePath` to the character node (leave empty if component is a direct child) |

---

## 5. Scene Setup

```
CharacterBody3D  (your script with get_input_snapshot + apply_net_movement)
 └─ NetworkedMovementComponent
```

If the component is **not** a direct child, set `target_node_path` to point at the character body.

---

## 6. Host / Join Flow

ApexNet expects a `GameManager` singleton at `/root/GameManager` with `host_game()` / `join_game(address)` methods and `send_with_latency(callable, args)` for simulated latency. You can replace this with your own networking bootstrap — the component only calls `send_with_latency` if the node exists; otherwise it uses `.rpc(...)` directly.

---

## 7. Input Map

Define actions in **Project → Project Settings → Input Map**:

| Action | Purpose |
|---|---|
| `move_left` / `move_right` | Strafe |
| `move_forward` / `move_back` | Forward / backward |
| `jump` | Jump (one-shot) |
| `sprint` | Sprint (hold) |
| `dash` | Dash (one-shot, optional) |
