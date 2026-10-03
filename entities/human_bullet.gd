extends Node2D
## 人类反派的可见子弹。

var velocity := Vector2.ZERO
var life := 0.0
var damage := 9.0

func setup(p: Vector2, dir: Vector2, speed: float = 360.0, hit_damage: float = 9.0) -> void:
	position = p
	velocity = dir.normalized() * speed
	life = 2.0
	damage = hit_damage
	z_index = 7
	queue_redraw()

func tick(delta: float, player: Node2D) -> bool:
	position += velocity * delta
	life -= delta
	if player != null and player.alive and position.distance_squared_to(player.position) <= 32.0 * 32.0:
		player.take_damage(damage)
		return true
	queue_redraw()
	return life <= 0.0 or absf(position.x) > GameData.ARENA_HALF_SIZE or absf(position.y) > GameData.ARENA_HALF_SIZE

func _draw() -> void:
	draw_line(-velocity.normalized() * 10.0, velocity.normalized() * 5.0, Color("#ffcf67"), 3.0)
	draw_circle(Vector2.ZERO, 3.0, Color("#fff0a6"))
