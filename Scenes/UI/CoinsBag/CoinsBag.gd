extends HBoxContainer
class_name CoinsBag

@onready var coins: Label = $Coins

func _process(delta: float) -> void:
	coins.text = str(Global.coins)
