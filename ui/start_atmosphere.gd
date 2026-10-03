extends Control
## 开始页动态氛围层：雾、灰烬和远处灯光呼吸。

var _time := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)

func _process(delta: float) -> void:
	_time += delta
	queue_redraw()

func _draw() -> void:
	var size := get_viewport_rect().size
	# 轻微的屏幕暗角与扫描线，把高清背景压成参考图里的像素终端质感。
	draw_rect(Rect2(0.0, 0.0, size.x, size.y * 0.22), Color(0.01, 0.015, 0.02, 0.20))
	draw_rect(Rect2(0.0, size.y * 0.82, size.x, size.y * 0.18), Color(0.01, 0.012, 0.01, 0.28))
	for y in range(0, int(size.y), 4):
		draw_line(Vector2(0.0, y), Vector2(size.x, y), Color(0.8, 0.76, 0.62, 0.018), 1.0)

	# 低处雾带缓慢横移，和背景的废墟透视保持一致。
	for i in 6:
		var y := size.y * (0.42 + float(i) * 0.075)
		var drift := fmod(_time * (10.0 + i * 3.0) + i * 170.0, size.x + 360.0) - 180.0
		var fog := Color(0.72, 0.78, 0.76, 0.055 - i * 0.004)
		draw_circle(Vector2(drift, y), 150.0 + i * 22.0, fog)
		draw_circle(Vector2(drift + 230.0, y + 15.0), 110.0 + i * 18.0, fog)
	# 远处警示灯呼吸闪烁。
	for i in 4:
		var x := size.x * (0.18 + i * 0.22)
		var y := size.y * (0.34 + fmod(i * 0.13, 0.22))
		var pulse := 0.25 + 0.2 * (sin(_time * 1.8 + i * 1.7) * 0.5 + 0.5)
		draw_circle(Vector2(x, y), 3.0, Color(1.0, 0.58, 0.22, pulse))
		draw_circle(Vector2(x, y), 13.0, Color(1.0, 0.38, 0.12, pulse * 0.12))
	# 少量灰烬粒子上浮。
	for i in 18:
		var x := fmod(i * 97.0 + _time * (12.0 + i % 4 * 5.0), size.x)
		var y := size.y - fmod(i * 43.0 + _time * (8.0 + i % 3 * 4.0), size.y * 0.72)
		draw_circle(Vector2(x, y), 1.0 + (i % 2), Color(0.9, 0.76, 0.55, 0.24))
