extends Node

signal on_create_block_text(unit: Node2D)
signal on_create_damage_text(unit: Node2D, hitbox: HitboxComponent)
signal on_create_heal_text(unit: Node2D, heal: float)

signal on_upgrade_selected
signal on_enemy_died(enemy: Enemy)

var coins: int = 500
var player: Player
var game_paused := false
var main_player_selected: UnitStats
var main_weapon_selected: ItemWeapon
var equipped_weapons: Array[ItemWeapon]

const FLASH_MATERIAL = preload("res://Effects/FlashMaterial.tres")
const FLOATING_TEXT_SCENE = preload("res://Scenes/UI/FloatingText/FloatingText.tscn")
const COINS_SCENE = preload("res://Scenes/Coins/Coins.tscn")
const ITEM_CARD_SCENE = preload("res://Scenes/UI/ItemCard/ItemCard.tscn")
const SELECTION_CARD_SCENE = preload("res://Scenes/UI/SelectionPanel/SelectionCard.tscn")
const COMMON_STYLE = preload("res://Styles/CommonStyle.tres")
const SPAWN_EFFECT_SCENE = preload("res://Scenes/Effects/EnemySpawnEffect.tscn")
const EPIC_STYLE = preload("res://Styles/EpicStyle.tres")
const LEGENDARY_STYLE = preload("res://Styles/LegendaryStyle.tres")
const RARE_STYLE = preload("res://Styles/RareStyle.tres")

const UPGRADE_PROBABILITY_CONFIG = {
	"rare": { "start_wave": 2, "base_multi": 0.06 },
	"epic": { "start_wave": 4, "base_multi": 0.02 },
	"legendary": { "start_wave": 7, "base_multi": 0.0023 },
}

const SHOP_PROBABILITY_CONFIG = {
	"rare": { "start_wave": 2, "base_multi": 0.10 },
	"epic": { "start_wave": 4, "base_multi": 0.06 },
	"legendary": { "start_wave": 7, "base_multi": 0.01 },
}


const TIER_COLORS: Dictionary[UpgradeTier, Color] = {
	UpgradeTier.RARE: Color(0.0, 0.557, 0.741),
	UpgradeTier.EPIC: Color(0.478, 0.251, 0.71),
	UpgradeTier.LEGENDARY: Color(0.906, 0.212, 0.212),
}

var available_players: Dictionary[String, PackedScene] = {
	"Brawler": preload("res://Scenes/Unit/Players/PlayerBrawler.tscn"),
	"Bunny": preload("res://Scenes/Unit/Players/PlayerBunny.tscn"),
	"Crazy": preload("res://Scenes/Unit/Players/PlayerCrazy.tscn"),
	"Knight": preload("res://Scenes/Unit/Players/PlayerKnight.tscn"),
	"Well Rounded": preload("res://Scenes/Unit/Players/PlayerWellRounded.tscn")
}

enum UpgradeTier{
	COMMON,
	RARE,
	EPIC,
	LEGENDARY
}

func get_harvesting_coins() -> void:
	coins += player.stats.harvesting

func get_selected_player() -> Player:
	var player_scene := available_players[main_player_selected.name]
	var player_instance := player_scene.instantiate()
	player = player_instance
	return player


func get_chance_success(chance: float) -> bool:
	var random := randf_range(0, 1.0)
	if random < chance:
		return true
	return false
	
func get_tier_style(tier: UpgradeTier) -> StyleBoxFlat:
	match tier:
		UpgradeTier.COMMON:
			return COMMON_STYLE
		UpgradeTier.RARE:
			return RARE_STYLE
		UpgradeTier.EPIC:
			return EPIC_STYLE
		_:
			return LEGENDARY_STYLE
	

func calculate_tier_probability(current_wave: int, config: Dictionary) -> Array[float]:
	var common_chance := 0.0
	var rare_chance := 0.0
	var epic_chance := 0.0
	var legendary_chance := 0.0
	
	#Rare: Starts increasing from wave 2
	if current_wave >= config.rare.start_wave:
		rare_chance = min(1.0, (current_wave - 1) * config.rare.base_multi)
	#Epic: Starts increasing from wave 4
	if current_wave >= config.epic.start_wave:
		epic_chance = min(1.0, (current_wave - 3) * config.epic.base_multi)
	#Legendary: Starts increasing from wave 7
	if current_wave >= config.legendary.start_wave:
		legendary_chance = min(1.0, (current_wave - 6) * config.legendary.base_multi)
	
	#Player luck increases chance of finding higher tiers.
	#Example: 10 luck = 10% chance = 1.1 multiplier
	var luck_factor := 1.0 + (Global.player.stats.luck / 100)
	rare_chance *= luck_factor
	epic_chance *= luck_factor
	legendary_chance *= luck_factor
	
	#normalize probabilities
	var total_non_common_chances := rare_chance + epic_chance + legendary_chance
	if total_non_common_chances > 1.0:
		var scale_down := 1.0 / total_non_common_chances
		rare_chance *= scale_down
		epic_chance *= scale_down
		legendary_chance *= scale_down
		total_non_common_chances = 1.0
	
	# Common takes the remaining probability
	common_chance = 1.0 - total_non_common_chances
	#Debug Print
	print("Wave: %d, Luck: %.1f => Chances: C:%.2f R:%.2f E:%.2f L:%.2f" %
	[current_wave, Global.player.stats.luck, common_chance, rare_chance, epic_chance, legendary_chance])

	return [
		max(0.0, common_chance),
		max(0.0, rare_chance),
		max(0.0, epic_chance),
		max(0.0, legendary_chance),
	]

func select_items_for_offer(item_pool: Array, current_wave: int, config: Dictionary) -> Array:
	if item_pool.is_empty():
		push_warning("Item pool is empty! No items to offer.")
		return []  # Shop will show nothing, but no crash—maybe add a "Out of stock!" label later.

	var tier_chances := calculate_tier_probability(current_wave, config)
	
	var legendary_limit = tier_chances[3]
	var epic_limit = legendary_limit + tier_chances[2]
	var rare_limit = epic_limit + tier_chances[1]
	
	var offered_items: Array = []
	var attempts := 0
	const MAX_ATTEMPTS := 100  # Safety net; prevents long hangs even if super unlucky with rolls.
	
	while offered_items.size() < 4 and attempts < MAX_ATTEMPTS:
		attempts += 1
		var roll := randf()
		var chosen_tier_index := 0
		if roll < legendary_limit:
			chosen_tier_index = 3  # Legendary
		elif roll < epic_limit:
			chosen_tier_index = 2  # Epic
		elif roll < rare_limit:
			chosen_tier_index = 1  # Rare
			
		var potential_items: Array = []
		var current_search_tier_index := chosen_tier_index
		
		while potential_items.is_empty() and current_search_tier_index >= 0:
			potential_items = item_pool.filter(func(item: ItemBase): return item.item_tier == current_search_tier_index)
			
			if potential_items.is_empty():
				current_search_tier_index -= 1
		
		if not potential_items.is_empty():
			var selected_item = potential_items.pick_random()
			
			if not offered_items.has(selected_item):
				offered_items.append(selected_item)
			# Optional: If you want to allow duplicates as a last resort (e.g., after 50 fails), uncomment this:
			# elif attempts > 50:
			#     offered_items.append(selected_item)  # Fills to 4 with dupes if stuck.
	
	if attempts >= MAX_ATTEMPTS:
		push_warning("Max attempts hit in select_items_for_offer. Offering what we have: " + str(offered_items.size()) + " items.")
	
	if offered_items.size() < 4:
		print("Debug: Only found " + str(offered_items.size()) + " unique items for offer—pool might be small.")
	
	return offered_items
	
