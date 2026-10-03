extends Node2D
## 场地背景：地面色块 + 网格线 + 边界框。
##
## 为什么它必须是独立节点，而不是 Main 自己的 _draw()：
## 实体是按 z_index 分层的 —— 经验球 -2（贴地）、尸体 -1（压在活丧尸下面）、
## 活丧尸 0、子弹 5。而 Main 自己的画布项在 z_index = 0，
## 它画的地面会把**所有负层整个盖住**。
##
## 表现就是：经验球一颗都看不见、丧尸的死亡动画播了但看不到（看起来像凭空消失）。
## 这种 bug 跑一万帧 headless 也不会报一个错 —— 只有真的看一眼画面才发现得了。
##
## 把它摁到 z_index = -100，负层实体才真的画得出来。

const RENDERED_BACKDROP: Texture2D = preload("res://assets/backgrounds/street_city_background_dark.png")

var _rendered_backdrop: Sprite2D

func _ready() -> void:
	# 必须低于所有负层实体（经验球 -2 / 尸体 -1）
	z_index = -100
	_rendered_backdrop = Sprite2D.new()
	_rendered_backdrop.name = "RenderedStreetBackdrop"
	_rendered_backdrop.texture = RENDERED_BACKDROP
	# 在地面色块上方、实体下方叠加；半透明保留网格与边界参照。
	_rendered_backdrop.z_index = 1
	_rendered_backdrop.modulate = Color(1.0, 1.0, 1.0, 0.68)
	add_child(_rendered_backdrop)
	_sync_backdrop_to_camera()
	queue_redraw()


func _process(_delta: float) -> void:
	_sync_backdrop_to_camera()


func _sync_backdrop_to_camera() -> void:
	if _rendered_backdrop == null:
		return
	var camera := get_viewport().get_camera_2d()
	if camera != null:
		_rendered_backdrop.global_position = camera.get_screen_center_position()


## 网格线不是为了好看，是因为纯色地面上移动**没有任何参照物**，
## 玩家会觉得自己没在动。这是 2D 早期最容易忽略的一件事。
func _draw() -> void:
	var h := GameData.ARENA_HALF_SIZE
	var rect := Rect2(-h, -h, h * 2.0, h * 2.0)

	# 先铺一层"界外"。相机贴到场地边缘时会把界外拍进画面，
	# 没有这一层，那里露出的是引擎默认清屏色（浅灰），
	# 看起来像渲染坏了，而不是"你跑到场地尽头了"。
	# 半径给到 1.6 倍：相机最多能看到边界外半个视口，留够余量。
	var outer := h * 1.6
	draw_rect(Rect2(-outer, -outer, outer * 2.0, outer * 2.0), Color(0.055, 0.06, 0.072))

	draw_rect(rect, Color(0.115, 0.125, 0.135))

	# 一横一竖两条废弃公路。宽色块提供清晰的移动参照，也把大场地切成
	# 四个容易记忆的区域，玩家逃跑时能快速判断自己在哪。
	var road := Color(0.085, 0.09, 0.10)
	draw_rect(Rect2(-h, -115.0, h * 2.0, 230.0), road)
	draw_rect(Rect2(-115.0, -h, 230.0, h * 2.0), road)
	var dash := Color(0.78, 0.67, 0.34, 0.32)
	var d := -h
	while d < h:
		draw_rect(Rect2(d, -3.0, 58.0, 6.0), dash)
		draw_rect(Rect2(-3.0, d, 6.0, 58.0), dash)
		d += 118.0

	# 固定位置的裂缝和污渍。不用随机数，保证固定种子压测不会被背景消耗 RNG。
	for i in 70:
		var x := fmod(float(i * 719 + 137), h * 2.0 - 160.0) - h + 80.0
		var y := fmod(float(i * 431 + 293), h * 2.0 - 160.0) - h + 80.0
		var p := Vector2(x, y)
		var stain := Color(0.16, 0.09, 0.08, 0.16) if i % 3 == 0 else Color(0.03, 0.035, 0.04, 0.22)
		draw_circle(p, 7.0 + float(i % 5) * 2.2, stain)
		if i % 4 == 0:
			draw_line(p + Vector2(-12, -4), p + Vector2(13, 7), Color(0.03, 0.035, 0.04, 0.36), 2.0)

	# 路边固定设施：只画在背景层，不参与碰撞，给玩家提供方向参照。
	_draw_car(Vector2(-330.0, -188.0), 0.03, Color("#334b59"))
	_draw_car(Vector2(305.0, 182.0), PI + 0.05, Color("#5b3d3c"))
	_draw_car(Vector2(-210.0, 265.0), PI * 0.5, Color("#4f5144"))
	_draw_barricade(Vector2(270.0, -250.0), -0.12)
	_draw_barricade(Vector2(-275.0, 220.0), 0.18)

	var step := GameData.GRID_STEP
	var n := int(h * 2.0 / step)
	var line_col := Color(1.0, 1.0, 1.0, 0.035)
	for i in n + 1:
		var t := -h + float(i) * step
		draw_line(Vector2(t, -h), Vector2(t, h), line_col, 1.0)
		draw_line(Vector2(-h, t), Vector2(h, t), line_col, 1.0)

	# 边界：跑到边上时一眼能看出"到头了"
	draw_rect(rect, Color(0.85, 0.3, 0.28, 0.45), false, 4.0)


func _draw_car(pos: Vector2, angle: float, body: Color) -> void:
	draw_set_transform(pos, angle, Vector2.ONE)
	draw_rect(Rect2(-34.0, -15.0, 68.0, 30.0), Color(0.02, 0.025, 0.03, 0.42), true)
	draw_rect(Rect2(-30.0, -13.0, 60.0, 26.0), body, true)
	draw_rect(Rect2(-13.0, -10.0, 26.0, 20.0), Color(0.10, 0.16, 0.19, 0.88), true)
	draw_rect(Rect2(-24.0, -17.0, 12.0, 5.0), Color(0.025, 0.03, 0.035), true)
	draw_rect(Rect2(12.0, -17.0, 12.0, 5.0), Color(0.025, 0.03, 0.035), true)
	draw_rect(Rect2(-24.0, 12.0, 12.0, 5.0), Color(0.025, 0.03, 0.035), true)
	draw_rect(Rect2(12.0, 12.0, 12.0, 5.0), Color(0.025, 0.03, 0.035), true)
	draw_line(Vector2(-27.0, -7.0), Vector2(-27.0, 8.0), Color(0.92, 0.68, 0.32, 0.55), 3.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_barricade(pos: Vector2, angle: float) -> void:
	draw_set_transform(pos, angle, Vector2.ONE)
	draw_line(Vector2(-30.0, 0.0), Vector2(30.0, 0.0), Color(0.07, 0.055, 0.045, 0.8), 9.0)
	draw_line(Vector2(-28.0, -8.0), Vector2(28.0, -8.0), Color(0.75, 0.30, 0.18, 0.85), 4.0)
	draw_line(Vector2(-28.0, 8.0), Vector2(28.0, 8.0), Color(0.75, 0.30, 0.18, 0.85), 4.0)
	draw_line(Vector2(-22.0, -13.0), Vector2(-22.0, 13.0), Color(0.2, 0.16, 0.12, 0.9), 4.0)
	draw_line(Vector2(22.0, -13.0), Vector2(22.0, 13.0), Color(0.2, 0.16, 0.12, 0.9), 4.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
