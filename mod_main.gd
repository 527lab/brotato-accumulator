extends Node

# David-Accumulator 主程式
# - 在 ItemService.characters 註冊「累積者」角色（沿用 well_rounded 的外觀與起始武器，圖示換色）
# - 載入翻譯
# - 讀取設定，建立擊殺追蹤器（accumulator_tracker.gd）
#
# 時機說明：ModLoader 在自己的 _init() 裡建立 mod_main，這時 ItemService 等 autoload 還沒建立；
# mod_main 的 _ready() 會在 ModLoader 加入場景樹時觸發，此時所有 autoload 都已建立，
# 但 ProgressData._ready() 還沒跑，所以它的 add_unlocked_by_default() 會自動幫新角色解鎖並建立難度資料。

const MOD_ID := "David-Accumulator"
const LOG_NAME := "David-Accumulator:Main"
const CHARACTER_ID := "character_accumulator"
const USER_CONFIG_NAME := "user"
const BASE_CHARACTER_PATH := "res://items/characters/well_rounded/well_rounded_data.tres"
const ICON_VIRTUAL_PATH := "res://mods-unpacked/David-Accumulator/accumulator_icon.png"
const DRAWBACK_DAMAGE := -10

const DEFAULT_CONFIG := {
	"kills_per_bonus": 10,
	"bonus_amount": 1,
	"show_popup": true,
	"enable_drawback": false,
}

# 遊戲內設定面板的欄位：[key, 型別, 最小, 最大, 名稱翻譯鍵]
const SETTINGS := [
	["kills_per_bonus", "int", 1, 1000, "ACCUM_SET_KILLS"],
	["bonus_amount", "int", 1, 20, "ACCUM_SET_AMOUNT"],
	["show_popup", "bool", 0, 0, "ACCUM_SET_POPUP"],
	["enable_drawback", "bool", 0, 0, "ACCUM_SET_DRAWBACK"],
]

const MENU_MODS_SCRIPT := "res://ui/menus/pages/mods/menu_mods.gd"
const INGAME_MAIN_MENU_SCRIPT := "res://ui/menus/ingame/ingame_main_menu.gd"

const TRANSLATIONS := {
	"en": {
		"CHARACTER_ACCUMULATOR": "Accumulator",
		"EFFECT_ACCUMULATOR": "Every {0} kills, a random primary or secondary stat improves permanently",
		"EFFECT_ACCUMULATOR_POOL": "By {0} each time, always in your favor: item prices, enemy speed and enemy damage go down, enemy count goes up",
		"ACCUM_SETTINGS_BUTTON": "Accumulator settings",
		"ACCUM_SETTINGS_TITLE": "Accumulator settings",
		"ACCUM_SET_KILLS": "Kills needed per bonus",
		"ACCUM_SET_AMOUNT": "Amount added each time",
		"ACCUM_SET_POPUP": "Show popup on bonus",
		"ACCUM_SET_DRAWBACK": "Drawback: -10% damage (from the next run)",
		"ACCUM_SET_HINT": "Changes are saved right away. Kills needed and amount also apply to the current run.",
		"ACCUM_SET_RESET": "Reset to defaults",
		"ACCUM_SET_CLOSE": "Close",
	},
	"zh_TW": {
		"CHARACTER_ACCUMULATOR": "累積者",
		"EFFECT_ACCUMULATOR": "每擊殺 {0} 個敵人，隨機一項主要或次要屬性永久強化（整場累積）",
		"EFFECT_ACCUMULATOR_POOL": "每次 {0} 點，一律往有利方向：道具價格、敵人速度、敵人傷害減少，敵人數量增加",
		"ACCUM_SETTINGS_BUTTON": "累積者設定",
		"ACCUM_SETTINGS_TITLE": "累積者設定",
		"ACCUM_SET_KILLS": "觸發所需擊殺數",
		"ACCUM_SET_AMOUNT": "每次增加的數值",
		"ACCUM_SET_POPUP": "觸發時顯示提示",
		"ACCUM_SET_DRAWBACK": "缺點：傷害 -10%（下一局開始生效）",
		"ACCUM_SET_HINT": "變更會立即存檔；擊殺數與增加量在目前這局也會馬上生效。",
		"ACCUM_SET_RESET": "恢復預設",
		"ACCUM_SET_CLOSE": "關閉",
	},
	"zh": {
		"CHARACTER_ACCUMULATOR": "累积者",
		"EFFECT_ACCUMULATOR": "每击杀 {0} 个敌人，随机一项主要或次要属性永久强化（整局累积）",
		"EFFECT_ACCUMULATOR_POOL": "每次 {0} 点，一律往有利方向：道具价格、敌人速度、敌人伤害减少，敌人数量增加",
		"ACCUM_SETTINGS_BUTTON": "累积者设置",
		"ACCUM_SETTINGS_TITLE": "累积者设置",
		"ACCUM_SET_KILLS": "触发所需击杀数",
		"ACCUM_SET_AMOUNT": "每次增加的数值",
		"ACCUM_SET_POPUP": "触发时显示提示",
		"ACCUM_SET_DRAWBACK": "缺点：伤害 -10%（下一局开始生效）",
		"ACCUM_SET_HINT": "更改会立即保存；击杀数与增加量在当前这局也会马上生效。",
		"ACCUM_SET_RESET": "恢复默认",
		"ACCUM_SET_CLOSE": "关闭",
	},
}

var dir_path := ""
var config := {}
var _active_config = null   # 正在使用、面板修改會寫回的 ModConfig
var _settings_panel_script = null
var _description_effects := []   # 所有建立過的說明效果 [擊殺數說明, 增加量說明]，改設定時原地更新數字
var character_data = null
var tracker = null


func _init() -> void:
	dir_path = get_script().resource_path.get_base_dir()
	ModLoaderLog.info("Accumulator loaded", LOG_NAME)


func _ready() -> void:
	load_config()
	_add_translations()
	_register_character()

	var tracker_script = load(dir_path.plus_file("accumulator_tracker.gd"))
	tracker = tracker_script.new()
	tracker.name = "AccumulatorTracker"
	tracker.mod_main = self
	add_child(tracker)

	_settings_panel_script = load(dir_path.plus_file("settings_panel.gd"))
	var err = get_tree().connect("node_added", self, "_on_node_added")
	if err != OK:
		ModLoaderLog.error("Cannot connect node_added for settings button (%s)" % err, LOG_NAME)

	ModLoaderLog.info(
		"Accumulator ready: character=%s config=%s"
		% [CHARACTER_ID, config],
		LOG_NAME
	)


# ---------- 設定 ----------
# 讀取順序：目前設定（若不是 default）> user.json > default（manifest 的預設值）
# 注意：ModLoader 每次啟動都會用 schema 重建 default.json，所以改 default.json 沒有用，要改 user.json。
func load_config() -> void:
	config = DEFAULT_CONFIG.duplicate()
	_active_config = null
	var current = ModLoaderConfig.get_current_config(MOD_ID)
	if current != null and current.name != ModLoaderConfig.DEFAULT_CONFIG_NAME:
		_active_config = current
	else:
		var all_configs: Dictionary = ModLoaderConfig.get_configs(MOD_ID)
		if all_configs.has(USER_CONFIG_NAME):
			_active_config = all_configs[USER_CONFIG_NAME]

	if _active_config != null and _active_config.data is Dictionary:
		for key in DEFAULT_CONFIG:
			if _active_config.data.has(key):
				config[key] = _active_config.data[key]
		ModLoaderLog.info("Using config: %s" % _active_config.name, LOG_NAME)
	else:
		ModLoaderLog.info("No user config yet, using defaults (will create user.json on first change)", LOG_NAME)
	_sanitize_config()


func _sanitize_config() -> void:
	for setting in SETTINGS:
		var key: String = setting[0]
		if setting[1] == "int":
			config[key] = int(clamp(int(config.get(key, DEFAULT_CONFIG[key])), setting[2], setting[3]))
		else:
			config[key] = bool(config.get(key, DEFAULT_CONFIG[key]))


func get_kills_per_bonus() -> int:
	return int(config.get("kills_per_bonus", 10))


func get_bonus_amount() -> int:
	return int(config.get("bonus_amount", 1))


func is_popup_enabled() -> bool:
	return bool(config.get("show_popup", true))


func is_drawback_enabled() -> bool:
	return bool(config.get("enable_drawback", false))


func get_config_value(key: String):
	return config.get(key, DEFAULT_CONFIG.get(key))


# 設定面板呼叫：改值 -> 存檔 -> 更新角色說明（擊殺數、增加量在目前這局立即生效，因為追蹤器每次都讀 config）
func set_config_value(key: String, value) -> void:
	if not DEFAULT_CONFIG.has(key):
		return
	config[key] = value
	_sanitize_config()
	_save_config()
	_refresh_character_effects()


func reset_config() -> void:
	config = DEFAULT_CONFIG.duplicate()
	_sanitize_config()
	_save_config()
	_refresh_character_effects()


func _save_config() -> void:
	if _active_config == null:
		var all_configs: Dictionary = ModLoaderConfig.get_configs(MOD_ID)
		if all_configs.has(USER_CONFIG_NAME):
			_active_config = all_configs[USER_CONFIG_NAME]
		else:
			_active_config = ModLoaderConfig.create_config(MOD_ID, USER_CONFIG_NAME, config.duplicate())
			if _active_config == null:
				ModLoaderLog.error("Cannot create user config", LOG_NAME)
				return
	_active_config.data = config.duplicate()
	if not _active_config.save_to_file():
		ModLoaderLog.error("Cannot save config to %s" % _active_config.save_path, LOG_NAME)
		return
	ModLoaderLog.info("Config saved (%s): %s" % [_active_config.name, config], LOG_NAME)


func _refresh_character_effects() -> void:
	if character_data != null:
		# 指定新陣列：已開局的角色副本仍保留原本的效果陣列，不會被中途加上或拿掉缺點
		character_data.effects = _build_effects()
	# 已開局的角色副本共用舊陣列；只更新說明數字，不增減缺點效果
	for pair in _description_effects:
		pair[0].value = get_kills_per_bonus()
		pair[1].value = get_bonus_amount()


# ---------- 遊戲內設定按鈕 ----------
# 主選單「模組」頁面（MenuMods）與遊戲中暫停選單（IngameMainMenu）各加一顆按鈕
func _on_node_added(node: Node) -> void:
	if not node is Control:
		return
	if _script_is(node, MENU_MODS_SCRIPT) or _script_is(node, INGAME_MAIN_MENU_SCRIPT):
		if not node.is_connected("ready", self, "_on_menu_ready"):
			node.connect("ready", self, "_on_menu_ready", [node], CONNECT_ONESHOT)


func _script_is(node: Node, path: String) -> bool:
	var script = node.get_script()
	while script != null:
		if script.resource_path == path:
			return true
		script = script.get_base_script()
	return false


func _on_menu_ready(menu: Node) -> void:
	call_deferred("_attach_settings", menu)


func _attach_settings(menu: Node) -> void:
	if not is_instance_valid(menu) or menu.has_meta("accumulator_settings_attached"):
		return
	menu.set_meta("accumulator_settings_attached", true)

	var anchor_button: Control = null
	var host: Control = null
	var input_blocker: Node = null

	if _script_is(menu, MENU_MODS_SCRIPT):
		anchor_button = menu.get_node_or_null("%BackButton")
		host = menu
		input_blocker = menu
	else:
		anchor_button = menu.get_node_or_null("%OptionsButton")
		# 暫停選單本體（PauseMenu）負責 Esc／返回，面板開著時要暫停它的輸入
		var pause_menu = menu.get_parent().get_parent() if menu.get_parent() != null else null
		if pause_menu != null and pause_menu.has_method("manage_back"):
			host = pause_menu
			input_blocker = pause_menu
		else:
			host = menu
			input_blocker = menu

	if anchor_button == null or host == null:
		ModLoaderLog.warning("Settings button not attached: anchor not found in %s" % menu.name, LOG_NAME)
		return

	var button := Button.new()
	button.name = "AccumulatorSettingsButton"
	button.text = tr("ACCUM_SETTINGS_BUTTON")
	button.focus_mode = Control.FOCUS_ALL
	var parent = anchor_button.get_parent()
	parent.add_child(button)
	if _script_is(menu, MENU_MODS_SCRIPT):
		parent.move_child(button, anchor_button.get_index())   # 放在「返回」上面
	else:
		parent.move_child(button, anchor_button.get_index() + 1)   # 放在「選項」下面

	var panel = _settings_panel_script.new()
	panel.name = "AccumulatorSettingsPanel"
	panel.mod_main = self
	panel.input_blocker = input_blocker
	panel.return_focus = button
	host.add_child(panel)
	button.connect("pressed", panel, "open")


# ---------- 翻譯 ----------
func _add_translations() -> void:
	for locale in TRANSLATIONS:
		var translation := Translation.new()
		translation.locale = locale
		var messages: Dictionary = TRANSLATIONS[locale]
		for key in messages:
			translation.add_message(key, messages[key])
		TranslationServer.add_translation(translation)


# ---------- 角色 ----------
func _register_character() -> void:
	for existing in ItemService.characters:
		if existing.my_id == CHARACTER_ID:
			character_data = existing
			ModLoaderLog.warning("Character already registered, skipping", LOG_NAME)
			return

	var base = load(BASE_CHARACTER_PATH)
	if base == null:
		ModLoaderLog.error("Cannot load base character %s" % BASE_CHARACTER_PATH, LOG_NAME)
		return

	var data := CharacterData.new()
	data.my_id = CHARACTER_ID
	data.name = "CHARACTER_ACCUMULATOR"
	data.unlocked_by_default = true
	data.can_be_looted = base.can_be_looted
	data.tier = 0
	data.value = 1
	data.icon = _make_icon(base.icon)
	data.item_appearances = base.item_appearances.duplicate()
	data.starting_weapons = base.starting_weapons.duplicate()
	data.starting_items = []
	data.tags = []
	data.wanted_tags = []
	data.banned_item_groups = []
	data.banned_items = []
	data.banned_upgrades = []
	data.effects = _build_effects()
	data.my_id_hash = Keys.generate_hash(CHARACTER_ID)

	ItemService.characters.append(data)
	character_data = data

	# 如果 ProgressData 已經初始化過（例如 mod 被重新載入），手動補上解鎖與難度資料
	if ProgressData.is_inside_tree():
		ProgressData.add_unlocked_by_default()

	ModLoaderLog.info("Registered character %s (total characters: %s)" % [CHARACTER_ID, ItemService.characters.size()], LOG_NAME)


func _build_effects() -> Array:
	var effects := []

	# 只用來顯示說明文字的效果：key 為空，套用時不會改任何數值
	var desc := Effect.new()
	desc.key = ""
	desc.text_key = "EFFECT_ACCUMULATOR"
	desc.value = get_kills_per_bonus()
	desc.effect_sign = Effect.Sign.NEUTRAL
	effects.append(desc)

	var pool_desc := Effect.new()
	pool_desc.key = ""
	pool_desc.text_key = "EFFECT_ACCUMULATOR_POOL"
	pool_desc.value = get_bonus_amount()
	pool_desc.effect_sign = Effect.Sign.NEUTRAL
	effects.append(pool_desc)
	_description_effects.append([desc, pool_desc])

	# 缺點：做成真正的角色效果，開局套用一次，存檔／續玩由原版機制處理，不會重複
	if is_drawback_enabled():
		var drawback := Effect.new()
		drawback.key = "stat_percent_damage"
		drawback.key_hash = Keys.generate_hash("stat_percent_damage")
		drawback.value = DRAWBACK_DAMAGE
		drawback.effect_sign = Effect.Sign.FROM_VALUE
		effects.append(drawback)

	return effects


# 用 well_rounded 的圖示做色相旋轉，讓選角畫面能分辨；失敗就沿用原圖
func _make_icon(source: Texture) -> Texture:
	if source == null:
		return null
	# StreamTexture.get_data() 每次都回傳新的 Image，可以直接修改
	var image: Image = source.get_data()
	if image == null:
		return source
	if image.is_compressed() and image.decompress() != OK:
		return source
	image.convert(Image.FORMAT_RGBA8)
	image.lock()
	for y in image.get_height():
		for x in image.get_width():
			var color: Color = image.get_pixel(x, y)
			if color.a > 0.0 and color.s > 0.15:
				color.h = fmod(color.h + 0.55, 1.0)
				image.set_pixel(x, y, color)
	image.unlock()
	var texture := ImageTexture.new()
	texture.create_from_image(image, source.flags)
	texture.take_over_path(ICON_VIRTUAL_PATH)
	return texture
