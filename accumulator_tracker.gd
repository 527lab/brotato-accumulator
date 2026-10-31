extends Node

# 擊殺追蹤：
# - 監聽場景樹，Main（每關的主場景）建立後連接 EntitySpawner.enemy_spawned，再連接每隻敵人的 died。
#   不擴充 main.gd，避開 class_name 腳本擴充的不確定性，也不和其他擴充 main.gd 的 mod 衝突。
# - 擊殺條件與原版 Main._on_enemy_died 相同：not _cleaning_up and args.enemy_killed_by_player
# - 計數存在玩家 effects 的自訂 key，原版存檔會原樣寫出、讀回，續玩保留；
#   「重打這一關」會回到該關開始時的狀態（與原版其他進度一致）。

const LOG_NAME := "David-Accumulator:Tracker"
const CHARACTER_ID := "character_accumulator"
const KILL_COUNT_KEY := "accumulator_kill_count"
const BONUS_TOTAL_KEY := "accumulator_bonus_total"

# 抽選池：遊戲屬性面板「主要」與「次要」兩個分頁上的全部數值（stats_container.tscn）。
# 每項：[effects key, 方向（+1/-1，對玩家有利；實際變動量再乘上設定的 bonus_amount）, 顯示名稱翻譯鍵]
# - 商店價格、敵人速度、敵人傷害：減少
# - 敵人數量：增加（更多敵人 = 更多經驗與材料）
# - 地圖大小等不在面板上的數值不會被抽到
const STAT_POOL := [
	# 主要（16）
	["stat_max_hp", 1, "STAT_MAX_HP"],
	["stat_hp_regeneration", 1, "STAT_HP_REGENERATION"],
	["stat_lifesteal", 1, "STAT_LIFESTEAL"],
	["stat_percent_damage", 1, "STAT_PERCENT_DAMAGE"],
	["stat_melee_damage", 1, "STAT_MELEE_DAMAGE"],
	["stat_ranged_damage", 1, "STAT_RANGED_DAMAGE"],
	["stat_elemental_damage", 1, "STAT_ELEMENTAL_DAMAGE"],
	["stat_attack_speed", 1, "STAT_ATTACK_SPEED"],
	["stat_crit_chance", 1, "STAT_CRIT_CHANCE"],
	["stat_engineering", 1, "STAT_ENGINEERING"],
	["stat_range", 1, "STAT_RANGE"],
	["stat_armor", 1, "STAT_ARMOR"],
	["stat_dodge", 1, "STAT_DODGE"],
	["stat_speed", 1, "STAT_SPEED"],
	["stat_luck", 1, "STAT_LUCK"],
	["stat_harvesting", 1, "STAT_HARVESTING"],
	# 次要（23）
	["consumable_heal", 1, "CONSUMABLE_HEAL"],
	["heal_when_pickup_gold", 1, "CHANCE_HEAL_ON_GOLD"],
	["xp_gain", 1, "XP_GAIN"],
	["pickup_range", 1, "PICKUP_RANGE"],
	["items_price", -1, "ITEMS_PRICE"],
	["explosion_damage", 1, "EXPLOSION_DAMAGE"],
	["explosion_size", 1, "EXPLOSION_SIZE"],
	["bounce", 1, "BOUNCE"],
	["piercing", 1, "PIERCING"],
	["piercing_damage", 1, "PIERCING_DAMAGE"],
	["damage_against_bosses", 1, "DAMAGE_AGAINST_BOSSES"],
	["structure_attack_speed", 1, "STRUCTURE_ATTACK_SPEED"],
	["structure_range", 1, "STRUCTURE_RANGE"],
	["burning_cooldown_reduction", 1, "BURNING_COOLDOWN_REDUCTION"],
	["burning_spread", 1, "BURNING_SPREAD"],
	["knockback", 1, "KNOCKBACK"],
	["chance_double_gold", 1, "CHANCE_DOUBLE_GOLD"],
	["item_box_gold", 1, "ITEM_BOX_GOLD"],
	["free_rerolls", 1, "FREE_REROLLS"],
	["trees", 1, "TREES"],
	["number_of_enemies", 1, "PCT_NUMBER_OF_ENEMIES"],
	["enemy_speed", -1, "PCT_ENEMY_SPEED"],
	["enemy_damage", -1, "ENEMY_DAMAGE"],
]

const POPUP_COLOR := Color(1.0, 0.85, 0.3)

var mod_main = null
var _main = null
var _kill_key := 0
var _bonus_total_key := 0
var _pool := []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_kill_key = Keys.generate_hash(KILL_COUNT_KEY)
	_bonus_total_key = Keys.generate_hash(BONUS_TOTAL_KEY)
	var err = get_tree().connect("node_added", self, "_on_node_added")
	if err != OK:
		ModLoaderLog.error("Cannot connect node_added (%s)" % err, LOG_NAME)


func _on_node_added(node: Node) -> void:
	# Main 場景是 root 底下名為 Main、有 _on_enemy_died 方法的節點
	if node.name != "Main" or node.get_parent() != get_tree().root:
		return
	if not node.has_method("_on_enemy_died"):
		return
	_main = node
	if not node.is_connected("ready", self, "_on_main_ready"):
		node.connect("ready", self, "_on_main_ready", [node], CONNECT_ONESHOT)


func _on_main_ready(main: Node) -> void:
	if not is_instance_valid(main):
		return
	_main = main
	var spawner = main.get("_entity_spawner")
	if spawner == null:
		ModLoaderLog.error("Main has no _entity_spawner, kill tracking disabled this wave", LOG_NAME)
		return
	if not spawner.is_connected("enemy_spawned", self, "_on_enemy_spawned"):
		spawner.connect("enemy_spawned", self, "_on_enemy_spawned")

	_pool = _build_pool()

	for player_index in RunData.get_player_count():
		if _is_accumulator(player_index):
			var effects: Dictionary = RunData.get_player_effects(player_index)
			ModLoaderLog.info(
				"Wave %s: player %s is Accumulator, kills=%s/%s, bonuses so far=%s, pool size=%s"
				% [RunData.current_wave, player_index, int(effects.get(_kill_key, 0)), mod_main.get_kills_per_bonus(), int(effects.get(_bonus_total_key, 0)), _pool.size()],
				LOG_NAME
			)


func _on_enemy_spawned(enemy: Node) -> void:
	if is_instance_valid(enemy) and not enemy.is_connected("died", self, "_on_enemy_died"):
		enemy.connect("died", self, "_on_enemy_died")


func _on_enemy_died(_enemy, args) -> void:
	if _main == null or not is_instance_valid(_main):
		return
	if args == null or args.cleaning_up or not args.enemy_killed_by_player:
		return
	if _main.get("_cleaning_up"):
		return

	var player_count: int = RunData.get_player_count()
	var player_index: int = args.killed_by_player_index
	if player_index < 0:
		# 沒有記錄擊殺者（例如部分環境傷害）時，單人模式算給唯一玩家，多人模式不計
		if player_count == 1:
			player_index = 0
		else:
			return
	if player_index >= player_count or not _is_accumulator(player_index):
		return

	var effects: Dictionary = RunData.get_player_effects(player_index)
	var kills: int = int(effects.get(_kill_key, 0)) + 1
	var needed: int = mod_main.get_kills_per_bonus()
	while kills >= needed:
		kills -= needed
		_grant_random_stat(player_index)
	effects[_kill_key] = kills


func _is_accumulator(player_index: int) -> bool:
	var character = RunData.get_player_character(player_index)
	return character != null and character.my_id == CHARACTER_ID


func _build_pool() -> Array:
	# [hash, delta, text_key, key]；只收玩家 effects 裡確實存在的 key
	var pool := []
	var sample: Dictionary = PlayerRunData.init_effects()
	for entry in STAT_POOL:
		var stat_hash: int = Keys.generate_hash(entry[0])
		if not sample.has(stat_hash):
			ModLoaderLog.warning("Stat %s not found in effects, skipped" % entry[0], LOG_NAME)
			continue
		pool.append([stat_hash, entry[1], entry[2], entry[0]])
	return pool


func _grant_random_stat(player_index: int) -> void:
	if _pool.empty():
		_pool = _build_pool()
		if _pool.empty():
			return
	var entry: Array = _pool[_rng.randi() % _pool.size()]
	var stat_hash: int = entry[0]
	var delta: int = int(entry[1]) * mod_main.get_bonus_amount()   # 方向 × 設定的增加量

	# 與 RunData.add_stat 相同的寫法，但不發 stat_added 信號（那只會觸發原版只有圖示的浮動提示），
	# 改由下面自己顯示含名稱的文字提示，show_popup 關閉時就完全不顯示。
	var effects: Dictionary = RunData.get_player_effects(player_index)
	effects[stat_hash] = effects.get(stat_hash, 0) + delta
	effects[_bonus_total_key] = int(effects.get(_bonus_total_key, 0)) + 1
	RunData._are_player_stats_dirty[player_index] = true
	Utils.reset_stat_cache(player_index)

	ModLoaderLog.debug("Player %s %s %s (total bonuses %s)" % [player_index, str(delta), entry[3], effects[_bonus_total_key]], LOG_NAME)

	if mod_main.is_popup_enabled():
		_show_popup(player_index, stat_hash, delta, entry[2])


func _show_popup(player_index: int, stat_hash: int, delta: int, text_key: String) -> void:
	var manager = _main.get("_floating_text_manager")
	var players = _main.get("_players")
	if manager == null or players == null or player_index >= players.size():
		return
	var player = players[player_index]
	if not is_instance_valid(player) or player.dead:
		return
	var text := get_bonus_text(delta, text_key)
	var icon = ItemService.get_stat_icon(stat_hash)
	manager.display(text, player.global_position - Vector2(0, 90), POPUP_COLOR, icon, manager.duration * 2.0, true, manager.direction, false)


# 「+1 最大HP」「+1% 攻擊速度」「-1% 道具價格」：翻譯值開頭的 % 移到數字後面；沒有翻譯就顯示 key
func get_bonus_text(delta: int, text_key: String) -> String:
	var number: String = ("+" + str(delta)) if delta > 0 else str(delta)
	var stat_name: String = tr(text_key)
	if stat_name == text_key or stat_name == "":
		stat_name = text_key.to_lower()
	stat_name = stat_name.strip_edges()
	if stat_name.begins_with("%"):
		return number + "% " + stat_name.substr(1).strip_edges()
	return number + " " + stat_name
