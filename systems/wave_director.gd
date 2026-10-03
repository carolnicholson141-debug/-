extends Node
## 波次导演：决定「什么时候刷、刷在哪、刷多少、刷多强」。
##
## 割草游戏的难度曲线其实只有一个自变量：时间。玩家不需要打关卡，
## 所以所有数值都挂在 elapsed 上。这里把曲线全部收在 GameData 里，
## 调难度就是在改那几个常数，不用碰这个文件。

## 由 Main 注入：真正去对象池取丧尸并初始化。参数 (数量, 是否精英)
var on_spawn: Callable = Callable()

var wave: int = 1
var elapsed: float = 0.0
var running: bool = false

var _wave_timer: float = 0.0
var _spawn_timer: float = 0.0
var _spawn_accum: float = 0.0
var _ring_radius: float = 900.0
var _next_elite_wave: int = GameData.ELITE_EVERY_WAVES
var _last_second: int = -1
var _last_wave_remaining: int = -1


func start(viewport_size: Vector2) -> void:
	wave = 1
	elapsed = 0.0
	_wave_timer = 0.0
	# 开局先让玩家有 1.5 秒喘息，别一进游戏脸上就有丧尸
	_spawn_timer = 1.5
	_spawn_accum = 0.0
	_next_elite_wave = GameData.ELITE_EVERY_WAVES
	_last_second = -1
	_last_wave_remaining = -1
	running = true

	# 刷怪环半径 = 视口对角线一半 + 余量，保证刷在视野外。
	# 用视口算而不是写死，是为了让 21:9 之类的宽屏也不会「凭空冒怪」。
	_ring_radius = viewport_size.length() * 0.5 + GameData.SPAWN_RING_MARGIN

	Events.wave_changed.emit(wave)


## 每帧由 Main 调用
func tick(delta: float, player_pos: Vector2, alive_count: int) -> void:
	if not running:
		return

	elapsed += delta
	_emit_time()

	# --- 波次推进
	_wave_timer += delta
	var remaining := ceili(GameData.WAVE_DURATION - _wave_timer)
	if remaining != _last_wave_remaining:
		_last_wave_remaining = remaining
		Events.wave_timer_changed.emit(remaining)
	if _wave_timer >= GameData.WAVE_DURATION:
		_wave_timer -= GameData.WAVE_DURATION
		wave += 1
		Events.wave_changed.emit(wave)
		_last_wave_remaining = -1
		if wave >= _next_elite_wave:
			_next_elite_wave += GameData.ELITE_EVERY_WAVES
			if wave % GameData.BOSS_EVERY_WAVES == 0:
				on_spawn.call(1, true, true, player_pos)
			var elite_count := mini(1 + maxi(0, int((wave - GameData.ELITE_EVERY_WAVES) / GameData.ELITE_EVERY_WAVES)), 5)
			for _i in elite_count:
				_spawn_elite(player_pos)

	# --- 常规刷怪
	if alive_count >= GameData.MAX_ALIVE:
		return

	_spawn_timer -= delta
	if _spawn_timer > 0.0:
		return
	_spawn_timer = GameData.spawn_interval(wave)

	# 用累加器处理「每波刷怪数量是小数」的情况：
	# 第 2 波是 1.25 只/次 → 实际表现是 4 次里 3 次刷 1 只、1 次刷 2 只。
	_spawn_accum += float(GameData.spawn_batch(wave))
	var count := int(floor(_spawn_accum))
	_spawn_accum -= float(count)

	count = mini(count, GameData.MAX_ALIVE - alive_count)
	if count <= 0 or not on_spawn.is_valid():
		return

	on_spawn.call(count, false, false, player_pos)


func _spawn_elite(player_pos: Vector2) -> void:
	if on_spawn.is_valid():
		on_spawn.call(1, true, false, player_pos)


## 在玩家视野外的环形区域随机取一个刷怪点
func random_spawn_point(player_pos: Vector2) -> Vector2:
	var angle := randf() * TAU
	var dist := _ring_radius * randf_range(1.0, 1.18)
	var p := player_pos + Vector2.RIGHT.rotated(angle) * dist

	# 场地边界是正方形，环上总会有一部分落在界外。
	# 直接夹紧会让界外的点堆到边上（看起来像从墙里钻出来），
	# 所以改成沿玩家反方向折返回界内。
	var lim := GameData.ARENA_HALF_SIZE - 40.0
	if absf(p.x) > lim or absf(p.y) > lim:
		p.x = clampf(p.x, -lim, lim)
		p.y = clampf(p.y, -lim, lim)
		var back := player_pos - p
		if back.length_squared() > 0.001:
			p += back.normalized() * minf(dist * 0.35, 260.0)

	return p


## 距离下一波还有多久（HUD 用）
func time_to_next_wave() -> float:
	return maxf(0.0, GameData.WAVE_DURATION - _wave_timer)


func _emit_time() -> void:
	# 整秒变了才发信号。比"每帧判断 fmod"更稳，也不依赖 delta 精度。
	var s := int(elapsed)
	if s != _last_second:
		_last_second = s
		Events.elapsed_time_changed.emit(elapsed)
