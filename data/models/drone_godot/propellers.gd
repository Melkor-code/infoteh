extends Node3D
## Attach to the parent of the imported drone. Rotor speeds are radians/second.
@export var rotor_speed: float = 75.0
var rotors: Array[Node3D] = []

func _ready() -> void:
	for index in range(4):
		var rotor := find_child("Propeller_%d" % index, true, false) as Node3D
		if rotor != null:
			rotors.append(rotor)

func _process(delta: float) -> void:
	for index in range(rotors.size()):
		var direction := 1.0 if index == 0 or index == 3 else -1.0
		rotors[index].rotate_y(direction * rotor_speed * delta)
