extends Node2D
## 静态地图装饰层（阶段3）：积水、排水沟、焚毁废车、木箱、路障、垃圾、围栏、路灯、地标。
##
## 层级：挂在 ArenaBackground 下、z_index = 2（相对）——
## 街景贴图（backdrop，相对 z=1）之上、实体层（0）之下，装饰压在街景上但不会挡怪。
##
## 两条铁律：
##   1. **不消耗 RNG** —— 所有位置用 fmod 伪随机公式（与背景裂缝同一做法），
##      固定种子下整张地图完全可复现；
##   2. **只在 _ready 画一次** —— 静态内容，运行期零每帧开销。
##
## 色板统一走蓝灰（与街景一致），暖色只留给路灯灯光和少数警示件。

const ARENA := 2200.0   # 装饰撒布范围（场地半宽 2400，留边界带）


func _ready() -> void:
	z_index = 2
	queue_redraw()


## 确定性伪随机：第 i 个元素、第 salt 组的坐标。
func _det(i: int, salt: int, span: float) -> float:
	return fmod(float(i * 719 + salt * 137), span) - span * 0.5


func _draw() -> void:
	_draw_landmark()
	_draw_fences()
	_draw_drains()
	_draw_puddles()
	_draw_wrecks()
	_draw_crates()
	_draw_trash()
	_draw_barricades()
	_draw_streetlights()


## ---- 排水沟：沿两条废弃公路的路缘等距布置 ----
func _draw_drains() -> void:
	var grate := Color(0.075, 0.085, 0.095)
	var rim := Color(0.16, 0.175, 0.19)
	for i in 8:
		var along := -ARENA + 240.0 + float(i) * 620.0
		var side := 1.0 if i % 2 == 0 else -1.0
		var vertical := i % 4 >= 2   # 后一半撒在竖路上
		var pos := Vector2(along, 150.0 * side)
		var angle := 0.0
		if vertical:
			pos = Vector2(150.0 * side, along)
			angle = PI * 0.5
		draw_set_transform(pos, angle, Vector2.ONE)
		draw_rect(Rect2(-23.0, -11.0, 46.0, 22.0), grate, true)
		draw_rect(Rect2(-23.0, -11.0, 46.0, 22.0), rim, false, 1.5)
		for s in 5:
			draw_rect(Rect2(-18.0 + float(s) * 8.0, -8.0, 3.0, 16.0), Color(0.03, 0.035, 0.04, 0.9), true)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## ---- 积水：街区里的小水洼（比水域更碎，纯视觉）----
func _draw_puddles() -> void:
	for i in 10:
		var x := _det(i, 3, ARENA * 2.0)
		var y := _det(i, 11, ARENA * 2.0)
		if absf(x) < 200.0 and absf(y) < 200.0:
			continue   # 别压在出生点上
		var rx := 20.0 + float(i % 4) * 9.0
		var ry := rx * (0.45 + float(i % 3) * 0.12)
		var a := float(i) * 1.3
		draw_set_transform(Vector2(x, y), a, Vector2(1.0, ry / rx))
		draw_circle(Vector2.ZERO, rx, Color(0.11, 0.17, 0.22, 0.55))
		draw_circle(Vector2.ZERO, rx * 0.8, Color(0.14, 0.21, 0.27, 0.4))
		# 一弯反光，让水面"湿"
		draw_arc(Vector2(-rx * 0.15, -ry * 0.2), rx * 0.55, PI * 1.05, PI * 1.7, 12, Color(0.45, 0.60, 0.70, 0.22), 1.6, true)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## ---- 焚毁废车：与背景 _draw_car 同族但更焦黑 ----
func _draw_wrecks() -> void:
	var wrecks := [
		[Vector2(-1050.0, 620.0), 0.45],
		[Vector2(1520.0, -680.0), -2.2],
	]
	for w in wrecks:
		var pos: Vector2 = w[0]
		var ang: float = w[1]
		draw_set_transform(pos, ang, Vector2.ONE)
		draw_rect(Rect2(-36.0, -17.0, 72.0, 34.0), Color(0.02, 0.022, 0.026, 0.55), true)
		draw_rect(Rect2(-32.0, -14.0, 64.0, 28.0), Color(0.10, 0.105, 0.11), true)
		draw_rect(Rect2(-14.0, -11.0, 26.0, 22.0), Color(0.045, 0.05, 0.055), true)
		draw_rect(Rect2(-26.0, -18.0, 12.0, 5.0), Color(0.03, 0.032, 0.035), true)
		draw_rect(Rect2(12.0, -18.0, 12.0, 5.0), Color(0.03, 0.032, 0.035), true)
		# 焦痕
		draw_circle(Vector2(6.0, 0.0), 13.0, Color(0.02, 0.02, 0.022, 0.7))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## ---- 木箱：补给点观感，成对出现 ----
func _draw_crates() -> void:
	var wood := Color(0.24, 0.20, 0.155)
	var wood_dark := Color(0.16, 0.135, 0.105)
	for i in 6:
		var x := _det(i, 5, ARENA * 1.7)
		var y := _det(i, 9, ARENA * 1.7)
		if absf(x) < 240.0 and absf(y) < 240.0:
			continue
		var a := fmod(float(i) * 0.9, 0.7) - 0.35
		_draw_crate(Vector2(x, y), a, wood, wood_dark)
		if i % 2 == 0:
			_draw_crate(Vector2(x + 26.0, y + 8.0), a + 0.22, wood, wood_dark)


func _draw_crate(pos: Vector2, a: float, wood: Color, wood_dark: Color) -> void:
	draw_set_transform(pos, a, Vector2.ONE)
	draw_rect(Rect2(-12.0, -12.0, 24.0, 24.0), wood, true)
	draw_rect(Rect2(-12.0, -12.0, 24.0, 24.0), wood_dark, false, 2.0)
	draw_line(Vector2(-12.0, -12.0), Vector2(12.0, 12.0), wood_dark, 2.5)
	draw_line(Vector2(12.0, -12.0), Vector2(-12.0, 12.0), wood_dark, 2.5)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## ---- 垃圾堆：黑色垃圾袋 + 碎屑 ----
func _draw_trash() -> void:
	for i in 14:
		var x := _det(i, 7, ARENA * 2.0)
		var y := _det(i, 13, ARENA * 2.0)
		if absf(x) < 220.0 and absf(y) < 220.0:
			continue
		for b in (2 + i % 3):
			var bx := x + _det(i * 3 + b, 17, 60.0)
			var by := y + _det(i * 3 + b, 19, 60.0)
			draw_circle(Vector2(bx, by), 4.5 + float((i + b) % 3), Color(0.045, 0.05, 0.055, 0.9))
			draw_circle(Vector2(bx - 1.0, by - 1.0), 2.0, Color(0.09, 0.095, 0.10, 0.8))
		# 碎纸/碎屑
		for d in 3:
			var dx := x + _det(i * 5 + d, 23, 46.0)
			var dy := y + _det(i * 5 + d, 29, 46.0)
			draw_rect(Rect2(dx, dy, 5.0, 3.0), Color(0.30, 0.32, 0.34, 0.5))


## ---- 路障：与背景层同款式，补几组封路位 ----
func _draw_barricades() -> void:
	var spots := [
		[Vector2(-620.0, 190.0), 0.08], [Vector2(760.0, -195.0), -0.05],
		[Vector2(195.0, 830.0), PI * 0.5 + 0.1], [Vector2(-230.0, -760.0), PI * 0.5 - 0.07],
	]
	for s in spots:
		var pos: Vector2 = s[0]
		var ang: float = s[1]
		draw_set_transform(pos, ang, Vector2.ONE)
		draw_line(Vector2(-30.0, 0.0), Vector2(30.0, 0.0), Color(0.07, 0.055, 0.045, 0.85), 9.0)
		draw_line(Vector2(-28.0, -8.0), Vector2(28.0, -8.0), Color(0.62, 0.26, 0.16, 0.9), 4.0)
		draw_line(Vector2(-28.0, 8.0), Vector2(28.0, 8.0), Color(0.62, 0.26, 0.16, 0.9), 4.0)
		draw_line(Vector2(-22.0, -13.0), Vector2(-22.0, 13.0), Color(0.18, 0.145, 0.11, 0.95), 4.0)
		draw_line(Vector2(22.0, -13.0), Vector2(22.0, 13.0), Color(0.18, 0.145, 0.11, 0.95), 4.0)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## ---- 围栏：三段铁艺护栏（立柱 + 双横杆）----
func _draw_fences() -> void:
	var steel := Color(0.30, 0.34, 0.38, 0.95)
	var steel_dark := Color(0.17, 0.19, 0.22, 0.95)
	var runs := [
		[Vector2(500.0, 420.0), 340.0, 0.0],
		[Vector2(-900.0, -520.0), 300.0, 0.0],
		[Vector2(780.0, -1200.0), 260.0, PI * 0.5],
	]
	for r in runs:
		var start: Vector2 = r[0]
		var length: float = r[1]
		var ang: float = r[2]
		var dir := Vector2.RIGHT.rotated(ang)
		var n := int(length / 34.0)
		for i in n + 1:
			var p := start + dir * (float(i) * 34.0)
			draw_rect(Rect2(p - Vector2(2.5, 2.5), Vector2(5.0, 5.0)), steel_dark, true)
		draw_line(start, start + dir * length, steel, 2.5)
		draw_line(start + Vector2(0, -7).rotated(ang), start + dir * length + Vector2(0, -7).rotated(ang), steel, 2.0)


## ---- 路灯：灯光池先画（压底），再立杆 ----
func _draw_streetlights() -> void:
	for i in 6:
		var along := -ARENA + 300.0 + float(i) * 880.0
		var side := 1.0 if i % 2 == 0 else -1.0
		var vertical := i % 4 >= 2
		var pos := Vector2(along, 168.0 * side)
		var lamp_dir := Vector2(0.0, -18.0 * side)
		if vertical:
			pos = Vector2(168.0 * side, along)
			lamp_dir = Vector2(-18.0 * side, 0.0)
		# 灯光池：两圈冷色叠加，蓝灰夜景的暖点缀
		draw_circle(pos + lamp_dir * 2.2, 64.0, Color(1.0, 0.82, 0.55, 0.05))
		draw_circle(pos + lamp_dir * 2.2, 40.0, Color(1.0, 0.85, 0.60, 0.07))
		# 灯杆
		draw_circle(pos, 4.5, Color(0.14, 0.155, 0.175))
		draw_circle(pos, 2.5, Color(0.24, 0.26, 0.29))
		var head := pos + lamp_dir * 2.2
		draw_line(pos, head, Color(0.20, 0.22, 0.25), 3.0)
		draw_circle(head, 3.5, Color(1.0, 0.90, 0.66, 0.95))
		draw_circle(head, 6.5, Color(1.0, 0.85, 0.55, 0.18))


## ---- 地标：断喷泉广场（东南象限）+ 水塔（西北象限）----
## 大场地需要"能报位置"的参照物：说"在水塔附近"比说坐标快得多。
func _draw_landmark() -> void:
	# --- 喷泉广场 ---
	var c := Vector2(1450.0, 1150.0)
	draw_circle(c, 170.0, Color(0.135, 0.145, 0.155))
	draw_arc(c, 170.0, 0.0, TAU, 64, Color(0.20, 0.22, 0.24, 0.8), 3.0, true)
	draw_arc(c, 150.0, 0.0, TAU, 64, Color(0.10, 0.11, 0.12, 0.5), 1.5, true)
	# 破喷泉：水池 + 断缺的池壁 + 中心残座
	draw_circle(c, 52.0, Color(0.10, 0.17, 0.22, 0.85))
	draw_arc(c, 52.0, 0.4, PI * 1.5, 40, Color(0.25, 0.27, 0.29), 5.0, true)
	draw_arc(c, 52.0, PI * 1.65, PI * 1.95, 12, Color(0.25, 0.27, 0.29), 5.0, true)
	draw_circle(c, 14.0, Color(0.20, 0.22, 0.24))
	draw_circle(c, 8.0, Color(0.12, 0.13, 0.14))
	# 四条长椅
	for k in 4:
		var a := TAU * float(k) / 4.0 + 0.4
		var bp := c + Vector2.RIGHT.rotated(a) * 105.0
		draw_set_transform(bp, a + PI * 0.5, Vector2.ONE)
		draw_rect(Rect2(-16.0, -4.0, 32.0, 8.0), Color(0.22, 0.19, 0.15), true)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 广场碎裂纹理
	for k in 8:
		var a := TAU * float(k) / 8.0 + 0.2
		var rp := c + Vector2.RIGHT.rotated(a) * (60.0 + float(k % 3) * 34.0)
		draw_circle(rp, 3.0 + float(k % 3), Color(0.07, 0.075, 0.08, 0.7))

	# --- 水塔（与水域题材呼应）---
	var t := Vector2(-1650.0, -1050.0)
	# 塔影
	draw_set_transform(t + Vector2(14.0, 18.0), 0.0, Vector2(1.0, 0.8))
	draw_circle(Vector2.ZERO, 34.0, Color(0.0, 0.0, 0.0, 0.25))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 支腿
	for k in 3:
		var a := TAU * float(k) / 3.0
		draw_line(t + Vector2.RIGHT.rotated(a) * 20.0, t + Vector2.RIGHT.rotated(a) * 30.0 - Vector2(0, -26), Color(0.16, 0.175, 0.19), 4.0)
	# 罐体：俯视就是个大圆 + 顶盖 + 锈迹
	draw_circle(t, 30.0, Color(0.23, 0.26, 0.28))
	draw_circle(t, 22.0, Color(0.28, 0.31, 0.33))
	draw_circle(t + Vector2(-6.0, -4.0), 7.0, Color(0.30, 0.20, 0.14, 0.8))
	draw_circle(t + Vector2(9.0, 8.0), 5.0, Color(0.30, 0.20, 0.14, 0.6))
	draw_arc(t, 30.0, 0.0, TAU, 40, Color(0.13, 0.145, 0.16), 3.0, true)
	draw_line(t + Vector2(-30.0, 0.0), t + Vector2(30.0, 0.0), Color(0.16, 0.175, 0.19, 0.7), 2.0)
