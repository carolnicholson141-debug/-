extends Control
## 升级三选一菜单。
##  
## 打开时游戏是暂停的（UpgradeSystem 负责 get_tree().paused = true），
## 所以本节点必须 PROCESS_MODE_ALWAYS，否则玩家点不动、游戏直接卡死。
##
## 交互同时支持鼠标点击和数字键 1/2/3 —— 割草游戏节奏快，
## 让玩家的手不用离开 WASD 就能选升级。

signal choice_picked(upgrade: Dictionary)

const CARD_SIZE := Vector2(260.0, 350.0)
## 原图只取没有文字的插画区域；每张海报排版不同，不能共用一组裁切比例。
const ICON_REGIONS := {
	"damage": Rect2(0.566, 0.398, 0.289, 0.230),
	"move_speed": Rect2(0.556, 0.416, 0.282, 0.221),
	"max_hp": Rect2(0.535, 0.430, 0.270, 0.205),
	"hard_shell": Rect2(0.575, 0.414, 0.279, 0.220),
	"shotgun": Rect2(0.580, 0.448, 0.270, 0.215),
	"multishot": Rect2(0.635, 0.390, 0.257, 0.272),
	"chain_amp": Rect2(0.674, 0.059, 0.255, 0.232),
	"field_magnet": Rect2(0.584, 0.400, 0.250, 0.209),
	"weakpoint": Rect2(0.635, 0.458, 0.271, 0.208),
	"pierce": Rect2(0.640, 0.425, 0.240, 0.206),
	"proj_speed": Rect2(0.288, 0.440, 0.534, 0.360),
}
const PIXEL_FONT := preload("res://assets/ui/fonts/fusion-pixel-12px-zh-hans.ttf")
const TITLE_ART := preload("res://assets/ui/hud/upgrade_title_banner.png")
const TEXTLESS_CARD_SKIN := preload("res://assets/ui/cards/card_skin_textless_v2.png")
const CARD_TINT_SHADER := preload("res://ui/card_skin_tint.gdshader")
const CARD_ART := {
	"damage": preload("res://assets/ui/cards/damage.png"),
	"move_speed": preload("res://assets/ui/cards/move_speed.png"),
	"max_hp": preload("res://assets/ui/cards/max_hp.png"),
	"multishot": preload("res://assets/ui/cards/multishot.png"),
	"shotgun": preload("res://assets/ui/cards/shotgun.png"),
	"chain_amp": preload("res://assets/ui/cards/chain_amp.png"),
	"weakpoint": preload("res://assets/ui/cards/weakpoint.png"),
	"pierce": preload("res://assets/ui/cards/pierce.png"),
	"proj_speed": preload("res://assets/ui/cards/proj_speed.png"),
	"field_magnet": preload("res://assets/ui/cards/field_magnet.png"),
	"hard_shell": preload("res://assets/ui/cards/hard_shell.png"),
}

## 可选注入：告诉我某个升级已经叠了几次，用于显示 "Lv 2 → 3"
var stack_provider: Callable = Callable()

## 可选注入：返回玩家当前属性表，用于在卡片上显示真实数值变化
## （"伤害 12.0 → 15.0" 而不是只有 "+25%"）。
## 拿不到时退回只显示百分比描述 —— 不接也能跑。
var stats_provider: Callable = Callable()

var _root_bg: ColorRect
var _cards_box: HBoxContainer
var _title: Label
var _subtitle: Label
var _title_art: TextureRect
var _cards: Array[Dictionary] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	add_theme_font_override("font", PIXEL_FONT)
	_fit_viewport()
	get_viewport().size_changed.connect(_fit_viewport)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()


func _fit_viewport() -> void:
	# 菜单直接挂在 CanvasLayer 下，没有 Control 父节点可以提供锚点尺寸。
	# 显式使用视口尺寸，才能让 CenterContainer 真正以游戏窗口中心为基准。
	position = Vector2.ZERO
	size = get_viewport().get_visible_rect().size


func _build() -> void:
	_root_bg = ColorRect.new()
	_root_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_bg.color = Color(0.025, 0.02, 0.016, 0.78)
	_root_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root_bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.anchor_left = 0.0
	center.anchor_top = 0.0
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	center.offset_left = 0.0
	center.offset_top = 0.0
	center.offset_right = 0.0
	center.offset_bottom = 0.0
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_title_art = TextureRect.new()
	_title_art.name = "UpgradeTitleArt"
	_title_art.texture = TITLE_ART
	_title_art.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_title_art.offset_left = -280.0
	_title_art.offset_right = 280.0
	_title_art.offset_top = 80.0
	_title_art.offset_bottom = 162.0
	_title_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_title_art.stretch_mode = TextureRect.STRETCH_SCALE
	_title_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_art.z_index = 1
	add_child(_title_art)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 26)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(column)

	_title = Label.new()
	_title.text = "选择一项强化"
	_title.add_theme_font_size_override("font_size", 30)
	_title.add_theme_color_override("font_color", Color("#f0c486"))
	_title.add_theme_color_override("font_outline_color", Color("#3c2b1c"))
	_title.add_theme_constant_override("outline_size", 5)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.visible = false
	column.add_child(_title)

	_subtitle = Label.new()
	_subtitle.text = "时间已暂停 · 你还可以选 1 张 · 选择后继续战斗"
	_subtitle.add_theme_font_size_override("font_size", 14)
	_subtitle.add_theme_color_override("font_color", Color(0.67, 0.72, 0.80, 0.95))
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_subtitle)

	_cards_box = HBoxContainer.new()
	_cards_box.add_theme_constant_override("separation", 20)
	_cards_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_cards_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_cards_box)


## ---------------------------------------------------------------- 打开 / 关闭

func open(choices: Array, remaining_count: int = 1) -> void:
	_clear_cards()
	_subtitle.text = "时间已暂停 · 你还可以选 %d 张 · 选择后继续战斗" % maxi(1, remaining_count)
	for i in choices.size():
		var upgrade: Dictionary = choices[i]
		_cards_box.add_child(_build_card(upgrade, i))
	visible = true
	# 让背景变暗动一下，避免菜单"啪"地跳出来毫无过渡
	modulate = Color(1, 1, 1, 0)
	var tw := create_tween()
	tw.tween_property(self, "modulate", Color(1, 1, 1, 1), 0.12)


func close() -> void:
	visible = false
	_clear_cards()


func _clear_cards() -> void:
	for c in _cards_box.get_children():
		_cards_box.remove_child(c)
		c.queue_free()
	_cards.clear()


## ---------------------------------------------------------------- 单张卡

func _build_card(upgrade: Dictionary, index: int) -> Control:
	var accent: Color = upgrade.get("color", Color("#7aa2d6"))
	var id := String(upgrade["id"])
	var panel := Panel.new()
	panel.name = "UpgradeCard_" + id
	panel.custom_minimum_size = CARD_SIZE
	panel.size = CARD_SIZE
	panel.pivot_offset = CARD_SIZE * 0.5
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _card_style(accent, false))
	var card_bg := ColorRect.new()
	card_bg.name = "CardBackground"
	card_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card_bg.color = Color(0.018, 0.035, 0.050, 1.0)
	card_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(card_bg)

	var skin := TextureRect.new()
	skin.name = "CardArt"
	skin.texture = TEXTLESS_CARD_SKIN
	skin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	skin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	skin.stretch_mode = TextureRect.STRETCH_SCALE
	skin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tint := ShaderMaterial.new()
	tint.shader = CARD_TINT_SHADER
	tint.set_shader_parameter("accent", accent.lightened(0.18))
	skin.material = tint
	panel.add_child(skin)

	_card_label(panel, "Badge", "◆ 强化卡牌  %02d" % (index + 1), Rect2(30, 30, 200, 22), 13, accent.lightened(0.45))
	_card_label(panel, "Title", String(upgrade["name"]), Rect2(30, 96, 200, 30), 24, Color("#edf5ff"))
	_card_label(panel, "Description", String(upgrade["desc"]), Rect2(30, 136, 200, 44), 14, Color("#d5e2ee"))
	var stat := String(upgrade["stat"])
	var format: Dictionary = GameData.STAT_FORMAT.get(stat, {})
	_card_label(panel, "StatName", String(format.get("label", "属性变化")), Rect2(30, 187, 128, 18), 12, accent.lightened(0.45))
	_card_label(panel, "Delta", _format_delta(upgrade), Rect2(30, 207, 130, 30), 17, Color("#9bffc6"))
	_card_label(panel, "SecondaryDelta", _format_secondary_delta(upgrade), Rect2(30, 248, 200, 28), 11, Color("#b7d7e8"))
	var used := int(stack_provider.call(id)) if stack_provider.is_valid() else 0
	_card_label(panel, "Stack", "Lv %d → %d  可无限强化" % [used, used + 1], Rect2(30, 281, 200, 20), 12, Color("#ccd7e3"))
	_card_label(panel, "KeyHint", "点击 或 按 [%d]" % (index + 1), Rect2(30, 306, 200, 22), 14, accent.lightened(0.50))

	var art: Texture2D = CARD_ART.get(id)
	if art != null:
		var atlas := AtlasTexture.new()
		atlas.atlas = art
		var region: Rect2 = ICON_REGIONS[id]
		atlas.region = Rect2(region.position * art.get_size(), region.size * art.get_size())
		atlas.filter_clip = true
		var holder := Control.new()
		holder.name = "Illustration"
		holder.position = Vector2(168, 187)
		holder.size = Vector2(64, 60)
		holder.clip_contents = true
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(holder)
		var illustration := TextureRect.new()
		illustration.texture = atlas
		illustration.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		illustration.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		illustration.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		illustration.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(illustration)

	panel.gui_input.connect(_on_card_input.bind(upgrade))
	panel.mouse_entered.connect(_on_card_hover.bind(panel, accent, true))
	panel.mouse_exited.connect(_on_card_hover.bind(panel, accent, false))
	_cards.append({"panel": panel, "upgrade": upgrade})
	return panel


func _card_label(parent: Control, node_name: String, text: String, rect: Rect2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = node_name
	label.text = text
	label.position = rect.position
	label.size = rect.size
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color("#041018"))
	label.add_theme_constant_override("outline_size", 3)
	parent.add_child(label)
	return label


func _format_secondary_delta(upgrade: Dictionary) -> String:
	if not stats_provider.is_valid():
		return ""
	var stats: Dictionary = stats_provider.call()
	var changes := PackedStringArray()
	var also: Dictionary = upgrade.get("also", {})
	for stat: String in also:
		if not stats.has(stat):
			continue
		var format: Dictionary = GameData.STAT_FORMAT.get(stat, {})
		changes.append("%s %s → %s" % [String(format.get("label", stat)),
			GameData.format_stat(stat, float(stats[stat])),
			GameData.format_stat(stat, float(stats[stat]) * float(also[stat]))])
	return "\n".join(changes)

## ---------------------------------------------------------------- 数值显示

## 把升级效果渲染成"旧值 → 新值"。
##
## 例：伤害 12.0 → 15.0 / 开火间隔 0.55s → 0.45s
##
## 拿不到属性表时退回空串（卡片上就不显示这一行），而不是瞎猜一个值 ——
## 显示错误的数字比不显示更糟。
func _format_delta(upgrade: Dictionary) -> String:
	if not stats_provider.is_valid():
		return ""
	var stats: Dictionary = stats_provider.call()
	if stats.is_empty():
		return ""

	var stat := String(upgrade["stat"])
	if not stats.has(stat):
		return ""

	var before := float(stats[stat])
	var after := GameData.preview_stat(stats, upgrade)

	# 叠加到上限后数值可能被 STAT_FLOOR 卡住不动，这时明确告诉玩家"已到上限"，
	# 否则"0.07 → 0.07"看起来像卡了 bug。
	if is_equal_approx(before, after):
		return "已达下限，不再提升"

	return "%s → %s" % [
		GameData.format_stat(stat, before),
		GameData.format_stat(stat, after),
	]


## 数值变化用箭头指示方向：变好=绿、变差=红（中国玩家的红涨绿跌习惯
## 在这里不适用 —— 这是"属性提升"不是"价格涨跌"，用绿=变好更符合通用直觉）。
func _delta_color(upgrade: Dictionary) -> Color:
	var stat := String(upgrade["stat"])
	# 开火间隔是"越小越好"，所以乘算 <1 反而是提升
	var better_when_lower := String(upgrade.get("better_when", "")) == "lower"
	var value := float(upgrade["value"])
	var improving := (value < 1.0) if better_when_lower else true
	if String(upgrade["op"]) == "add":
		improving = true
	return Color("#7ee09a") if improving else Color("#e08a7e")


func _card_style(accent: Color, hovered: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	var brass := accent.lerp(Color("#b28b54"), 0.45)
	sb.bg_color = Color(0.055, 0.075, 0.085, 0.98) if not hovered else Color(0.12, 0.16, 0.16, 0.99)
	sb.set_corner_radius_all(14)
	sb.border_color = brass if hovered else Color(brass.r, brass.g, brass.b, 0.70)
	sb.set_border_width_all(3 if hovered else 2)
	sb.shadow_color = Color(0.01, 0.008, 0.005, 0.62)
	sb.shadow_size = 14 if hovered else 7
	sb.shadow_offset = Vector2(0.0, 5.0)
	return sb


func _on_card_hover(panel: Panel, _accent: Color, hovered: bool) -> void:
	panel.add_theme_stylebox_override("panel", _card_style(_accent, hovered))
	var art := panel.get_node_or_null("CardArt") as TextureRect
	if art != null:
		art.modulate = Color(1.10, 1.10, 1.10, 1.0) if hovered else Color.WHITE
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(panel, "scale", Vector2(1.035, 1.035) if hovered else Vector2.ONE, 0.10)


func _on_card_input(event: InputEvent, upgrade: Dictionary) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_pick(upgrade)
			accept_event()


## ---------------------------------------------------------------- 输入

func _input(event: InputEvent) -> void:
	if not visible:
		return
	# 先 as 出具体类型再取属性。InputEvent 基类没有 pressed，直接 event.pressed 会炸。
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var idx := key.keycode - KEY_1
	if idx >= 0 and idx < _cards.size():
		_pick(_cards[idx]["upgrade"])
		get_viewport().set_input_as_handled()


func _pick(upgrade: Dictionary) -> void:
	close()
	choice_picked.emit(upgrade)
