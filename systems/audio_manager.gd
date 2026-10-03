extends Node
## 事件驱动的轻量音效管理器。
## 高频音效使用固定声道池，避免每次开枪/命中都创建新节点。

const STREAMS := {
	"shot": preload("res://assets/audio/shot.wav"),
	"hit": preload("res://assets/audio/hit.wav"),
	"kill": preload("res://assets/audio/kill.wav"),
	"xp": preload("res://assets/audio/xp.wav"),
	"levelup": preload("res://assets/audio/levelup.wav"),
	"hurt": preload("res://assets/audio/hurt.wav"),
	"gameover": preload("res://assets/audio/gameover.wav"),
}

const VOICES := {"shot": 5, "hit": 5, "kill": 3, "xp": 3, "levelup": 1, "hurt": 2, "gameover": 1}
var _pools: Dictionary = {}
var _cursor: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for key: String in STREAMS:
		var voices: Array[AudioStreamPlayer] = []
		for _i in int(VOICES[key]):
			var player := AudioStreamPlayer.new()
			player.stream = STREAMS[key]
			add_child(player)
			voices.append(player)
		_pools[key] = voices
		_cursor[key] = 0
	Events.weapon_fired.connect(func() -> void: _play("shot", -8.0, 0.96, 1.05))
	Events.enemy_hurt.connect(func(_pos: Vector2, _amount: float) -> void: _play("hit", -11.0, 0.92, 1.10))
	Events.enemy_killed.connect(func(_pos: Vector2, _xp: float, elite: bool) -> void: _play("kill", -5.0 if elite else -9.0, 0.90, 1.06))
	Events.xp_collected.connect(func(_value: float) -> void: _play("xp", -13.0, 0.97, 1.08))
	Events.level_up_requested.connect(func(_level: int) -> void: _play("levelup", -5.0, 1.0, 1.0))
	Events.player_hurt.connect(func(_pos: Vector2, _amount: float) -> void: _play("hurt", -5.0, 0.96, 1.03))
	Events.game_over.connect(func(_summary: Dictionary) -> void: _play("gameover", -4.0, 1.0, 1.0))

func _play(key: String, volume_db: float, pitch_min: float, pitch_max: float) -> void:
	var voices: Array = _pools[key]
	var index := int(_cursor[key])
	var player: AudioStreamPlayer = voices[index]
	_cursor[key] = (index + 1) % voices.size()
	player.volume_db = volume_db
	player.pitch_scale = randf_range(pitch_min, pitch_max)
	player.play()


func _exit_tree() -> void:
	# 退出时主动停止并释放声道，避免仍在播放的 AudioStreamPlayback
	# 把 WAV 资源保持到引擎清理阶段，造成假性资源泄漏警告。
	for voices: Array in _pools.values():
		for player: AudioStreamPlayer in voices:
			player.stop()
			player.free()
	_pools.clear()
	_cursor.clear()
