extends Control

# 累積者設定面板（遮罩＋置中面板）。
# 掛在容器型的宿主底下（MenuMods／PauseMenu），由容器撐滿；繼承宿主的主題與字型。
# 開啟時暫停 input_blocker 的 _input（避免 Esc 直接關掉暫停選單或返回上一頁），
# 用按鍵關閉時等按鍵放開才還原。

var mod_main = null
var input_blocker: Node = null
var return_focus: Control = null

var _controls := {}
var _first_focus: Control = null
var _reenable_on_release := false


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS
	mouse_filter = MOUSE_FILTER_STOP
	_build()
	hide()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.8)
	dim.anchor_right = 1.0
	dim.anchor_bottom = 1.0
	dim.mouse_filter = MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	center.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_constant_override(side, 24)
	panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_constant_override("separation", 16)
	root.rect_min_size = Vector2(760, 0)
	margin.add_child(root)

	var title := Label.new()
	title.text = tr("ACCUM_SETTINGS_TITLE")
	title.align = Label.ALIGN_CENTER
	root.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_constant_override("hseparation", 24)
	grid.add_constant_override("vseparation", 12)
	root.add_child(grid)

	for setting in mod_main.SETTINGS:
		var key: String = setting[0]
		var label := Label.new()
		label.text = tr(setting[4])
		label.size_flags_horizontal = SIZE_EXPAND_FILL
		label.valign = Label.VALIGN_CENTER
		grid.add_child(label)

		var control = null
		if setting[1] == "int":
			var spin := SpinBox.new()
			spin.min_value = setting[2]
			spin.max_value = setting[3]
			spin.step = 1
			spin.rounded = true
			spin.rect_min_size = Vector2(180, 0)
			spin.connect("value_changed", self, "_on_int_changed", [key])
			control = spin
		else:
			var check := CheckBox.new()
			check.connect("toggled", self, "_on_bool_toggled", [key])
			control = check
		grid.add_child(control)
		_controls[key] = control
		if _first_focus == null:
			_first_focus = control.get_line_edit() if control is SpinBox else control

	var hint := Label.new()
	hint.text = tr("ACCUM_SET_HINT")
	hint.autowrap = true
	hint.modulate = Color(1, 1, 1, 0.75)
	root.add_child(hint)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGN_CENTER
	buttons.add_constant_override("separation", 24)
	root.add_child(buttons)

	var reset := Button.new()
	reset.text = tr("ACCUM_SET_RESET")
	reset.connect("pressed", self, "_on_reset_pressed")
	buttons.add_child(reset)

	var close_button := Button.new()
	close_button.text = tr("ACCUM_SET_CLOSE")
	close_button.connect("pressed", self, "close")
	buttons.add_child(close_button)


func _refresh_values() -> void:
	for setting in mod_main.SETTINGS:
		var key: String = setting[0]
		var control = _controls[key]
		control.set_block_signals(true)
		if control is SpinBox:
			control.value = int(mod_main.get_config_value(key))
		else:
			control.pressed = bool(mod_main.get_config_value(key))
		control.set_block_signals(false)


func open() -> void:
	_refresh_values()
	show()
	raise()
	if input_blocker != null and is_instance_valid(input_blocker):
		input_blocker.set_process_input(false)
	_reenable_on_release = false
	if _first_focus != null:
		_first_focus.grab_focus()


func close(from_key_press: bool = false) -> void:
	# SpinBox 正在輸入的文字要先套用
	for control in _controls.values():
		if control is SpinBox:
			control.apply()
	hide()
	if from_key_press:
		_reenable_on_release = true
	else:
		_restore_blocker()
	if return_focus != null and is_instance_valid(return_focus):
		return_focus.grab_focus()


func _restore_blocker() -> void:
	if input_blocker != null and is_instance_valid(input_blocker):
		input_blocker.set_process_input(true)


func _input(event: InputEvent) -> void:
	if _reenable_on_release:
		if event.is_action_released("ui_cancel") or event.is_action_released("ui_pause"):
			_reenable_on_release = false
			_restore_blocker()
			get_tree().set_input_as_handled()
		return
	if not visible:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("ui_pause"):
		close(true)
		get_tree().set_input_as_handled()


func _exit_tree() -> void:
	if visible or _reenable_on_release:
		_restore_blocker()


func _on_int_changed(value: float, key: String) -> void:
	mod_main.set_config_value(key, int(value))


func _on_bool_toggled(pressed: bool, key: String) -> void:
	mod_main.set_config_value(key, pressed)


func _on_reset_pressed() -> void:
	mod_main.reset_config()
	_refresh_values()
