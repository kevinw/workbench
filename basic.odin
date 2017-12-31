import "core:fmt.odin"
import "core:mem.odin"
import "core:math.odin"

//
// Array stuff
//

inst :: proc[inst_no_value, inst_value];
inst_no_value :: inline proc(array: ^[dynamic]$T) -> ^T {
	length := append(array, T{});
	return &array[length-1];
}
inst_value :: inline proc(array: ^[dynamic]$T, value: T) -> ^T {
	length := append(array, value);
	return &array[length-1];
}

remove :: proc(array: ^[dynamic]$T, to_remove: T) {
	for item, index in array {
		if item == to_remove {
			array[index] = array[len(array)-1];
			pop(array);
			return;
		}
	}
}
remove_by_index :: proc(array: ^[dynamic]$T, to_remove: int) {
	array[to_remove] = array[len(array)-1];
	pop(array);
}
remove_all :: proc(array: ^[dynamic]$T, to_remove: T) {
	for item, index in array {
		if item == to_remove {
			array[index] = array[len(array)-1];
			pop(array);
		}
	}
}

//
// Math
//

sqr_magnitude :: inline proc(a: math.Vec2) -> f32 do return math.dot(a, a);
magnitude :: inline proc(a: math.Vec2) -> f32 do return math.sqrt(math.dot(a, a));

move_toward :: proc(a, b: math.Vec2, step: f32) -> math.Vec2 {
	direction := b - a;
	mag := magnitude(direction);

	if mag <= step || mag == 0 {
		return b;
	}

	return a + direction / mag * step;
}

sqr :: inline proc(x: $T) -> T {
	return x * x;
}

distance :: inline proc(x, y: $T) -> f32 {
	diff := x - y;
	return math.sqrt(sqr(diff.x) + sqr(diff.y));
}

sqr_distance :: inline proc(x, y: $T) -> f32 {
	diff := x - y;
	return sqr(diff.x) + sqr(diff.y);
}

minv :: inline proc(args: ...$T) -> T {
	assert(len(args) > 0);
	current := args[0];
	for arg in args {
		if arg < current {
			current = arg;
		}
	}

	return current;
}

maxv :: inline proc(args: ...$T) -> T {
	assert(len(args) > 0);
	current := args[0];
	for arg in args {
		if arg > current {
			current = arg;
		}
	}
}

//
// Logging
//

logln :: proc(args: ...any, location := #caller_location) {
	last_slash_idx: int;

	// Find the last slash in the file path
	last_slash_idx = len(location.file_path) - 1;
	for last_slash_idx >= 0 {
		if location.file_path[last_slash_idx] == '\\' {
			break;
		}

		last_slash_idx -= 1;
	}

	if last_slash_idx < 0 do last_slash_idx = 0;

	file := location.file_path[last_slash_idx+1..len(location.file_path)];

	fmt.println(...args);
	fmt.printf("%s:%d:%s()", file, location.line, location.procedure);
	fmt.printf("\n\n");
}

//
// Strings
//

MAX_C_STR_LENGTH :: 1024;
to_c_string :: proc(str: string) -> [MAX_C_STR_LENGTH]byte {
	assert(len(str) < MAX_C_STR_LENGTH);
	result: [MAX_C_STR_LENGTH]byte;
	mem.copy(&result[0], &str[0], len(str));
	result[len(str)] = 0;
	return result;
}