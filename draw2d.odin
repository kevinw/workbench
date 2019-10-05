package workbench

using import        "core:math"
using import        "core:fmt"
      import        "core:sort"
      import        "core:strings"
      import        "core:mem"
      import        "core:os"

      import        "platform"
      import        "gpu"
      import wbmath "math"
using import        "types"
using import        "logging"

      import        "external/stb"
      import        "external/glfw"
      import        "external/imgui"

      import pf     "profiler"

//
// API
//

im_quad :: inline proc(
	rendermode: gpu.Rendermode_Proc,
	shader: gpu.Shader_Program,
	min, max: Vec2,
	color: Colorf,
	texture: gpu.Texture, // note(josh): can be empty
	auto_cast render_order: int = current_render_layer) {

		cmd := Draw_Command{
			render_order = render_order,
			serial_number = len(buffered_draw_commands),
			rendermode = rendermode,
			shader = shader,
			texture = texture,
			scissor = do_scissor,
			scissor_rect = current_scissor_rect,

			kind = Draw_Quad_Command {
				min = min,
				max = max,
				color = color,
			},
		};

		append(&buffered_draw_commands, cmd);
}
im_quad_pos :: inline proc(
	rendermode: gpu.Rendermode_Proc,
	shader: gpu.Shader_Program,
	pos, size: Vec2,
	color: Colorf,
	texture: gpu.Texture, // note(josh): can be empty
	auto_cast render_order: int = current_render_layer) {

		im_quad(rendermode, shader, pos-(size*0.5), pos+(size*0.5), color, texture, render_order);
}

im_sprite :: inline proc(
	rendermode: gpu.Rendermode_Proc,
	shader: gpu.Shader_Program,
	position, scale: Vec2,
	sprite: Sprite,
	color := Colorf{1, 1, 1, 1},
	pivot := Vec2{0.5, 0.5},
	auto_cast render_order: int = current_render_layer) {

		size := (Vec2{sprite.width, sprite.height} * scale);
		min := position;
		max := min + size;
		min -= size * pivot;
		max -= size * pivot;

		im_sprite_minmax(rendermode, shader, min, max, sprite, color, render_order);
}
im_sprite_minmax :: inline proc(
	rendermode: gpu.Rendermode_Proc,
	shader: gpu.Shader_Program,
	min, max: Vec2,
	sprite: Sprite,
	color := Colorf{1, 1, 1, 1},
	auto_cast render_order: int = current_render_layer) {

		cmd := Draw_Command{
			render_order = render_order,
			serial_number = len(buffered_draw_commands),
			rendermode = rendermode,
			shader = shader,
			texture = sprite.id,
			scissor = do_scissor,
			scissor_rect = current_scissor_rect,

			kind = Draw_Sprite_Command{
				min = min,
				max = max,
				color = color,
				uvs = sprite.uvs,
			},
		};

		append(&buffered_draw_commands, cmd);
}

im_text :: proc(
	rendermode: gpu.Rendermode_Proc,
	font: Font,
	str: string,
	position: Vec2,
	color: Colorf,
	size: f32,
	layer: int,
	actually_draw: bool = true,
	loc := #caller_location) -> f32 {

		// todo: make push_text() be render_mode agnostic
		// old := current_render_mode;
		// rendering_unit_space();
		// defer old();

		position := position;

		assert(rendermode == gpu.rendermode_unit);

		start := position;
		for _, i in str {
			c := str[i];
			is_space := c == ' ';
			if is_space do c = 'l'; // @DrawStringSpaces: @Hack:

			min, max: Vec2;
			whitespace_ratio: f32;
			quad: stb.Aligned_Quad;
			{
				//
				size_pixels: Vec2;
				// NOTE!!!!!!!!!!! quad x0 y0 is TOP LEFT and x1 y1 is BOTTOM RIGHT. // I think?!!!!???!!!!
				quad = stb.get_baked_quad(font.chars, font.dim, font.dim, cast(int)c, &size_pixels.x, &size_pixels.y, true);
				size_pixels.y = abs(quad.y1 - quad.y0);
				size_pixels *= size;

				ww := cast(f32)platform.current_window_width;
				hh := cast(f32)platform.current_window_height;
				// min = position + (Vec2{quad.x0, -quad.y1} * size);
				// max = position + (Vec2{quad.x1, -quad.y0} * size);
				min = position + (Vec2{quad.x0, -quad.y1} * size / Vec2{ww, hh});
				max = position + (Vec2{quad.x1, -quad.y0} * size / Vec2{ww, hh});
				// Padding
				{
					// todo(josh): @DrawStringSpaces: Currently dont handle spaces properly :/
					abs_hh := abs(quad.t1 - quad.t0);
					char_aspect: f32;
					if abs_hh == 0 {
						char_aspect = 1;
					}
					else {
						char_aspect = abs(quad.s1 - quad.s0) / abs(quad.t1 - quad.t0);
					}
					full_width := size_pixels.x;
					char_width := size_pixels.y * char_aspect;
					whitespace_ratio = 1 - (char_width / full_width);
				}
			}

			sprite: Sprite;
			{
				uv0 := Vec2{quad.s0, quad.t1};
				uv1 := Vec2{quad.s0, quad.t0};
				uv2 := Vec2{quad.s1, quad.t0};
				uv3 := Vec2{quad.s1, quad.t1};
				sprite = Sprite{{uv0, uv1, uv2, uv3}, 0, 0, font.texture};
			}

			if !is_space && actually_draw {
				im_sprite_minmax(rendermode, shader_text, min, max, sprite, color, layer);
			}

			width := max.x - min.x;
			position.x += width + (width * whitespace_ratio);
		}

		width := position.x - start.x;
		return width;
}

get_string_width :: inline proc(
	rendermode: gpu.Rendermode_Proc,
	font: Font,
	str: string,
	size: f32) -> f32 {

		return im_text(rendermode, font, str, {}, {}, size, 0, false);
}

// Camera utilities

@(deferred_out=im_pop_camera)
IM_PUSH_CAMERA :: proc(camera: ^gpu.Camera) -> ^gpu.Camera {
	return gpu.push_camera_non_deferred(camera);
}

@private
im_pop_camera :: proc(old_camera: ^gpu.Camera) {
	im_flush();
	gpu.pop_camera(old_camera);
}

// Render layers

@(deferred_out=pop_render_layer)
PUSH_RENDER_LAYER :: proc(auto_cast layer: int) -> int {
	tmp := current_render_layer;
	current_render_layer = layer;
	return tmp;
}

@private
pop_render_layer :: proc(layer: int) {
	current_render_layer = layer;
}



// Scissor

im_scissor :: proc(x1, y1, ww, hh: int) {
	if do_scissor do logln("You are nesting scissors. I don't know if this is a problem, if it's not you can delete this log");
	do_scissor = true;
	current_scissor_rect = {x1, y1, ww, hh};
}

im_scissor_end :: proc() {
	assert(do_scissor);
	do_scissor = false;
	current_scissor_rect = {0, 0, cast(int)(platform.current_window_width+0.5), cast(int)(platform.current_window_height+0.5)};
}



//
// Internal
//

_internal_im_model: gpu.Model;
buffered_draw_commands: [dynamic]Draw_Command;

do_scissor: bool;
current_scissor_rect: [4]int;

current_render_layer: int;

im_flush :: proc() {
	pf.TIMED_SECTION(&wb_profiler);

	cmds := &buffered_draw_commands;

	if cmds == nil do return;
	if len(cmds) == 0 do return;

	defer clear(cmds);


	sort.quick_sort_proc(cmds[:], proc(a, b: Draw_Command) -> int {
			diff := a.render_order - b.render_order;
			if diff != 0 do return diff;
			return a.serial_number - b.serial_number;
		});

	@static im_queued_for_drawing: [dynamic]gpu.Vertex2D;

	current_rendermode : gpu.Rendermode_Proc = nil;
	is_scissor := false;
	current_shader := gpu.Shader_Program(0);
	current_texture: gpu.Texture;

	command_loop:
	for cmd in cmds {
		shader_mismatch     := cmd.shader          != current_shader;
		texture_mismatch    := cmd.texture.gpu_id  != current_texture.gpu_id;
		scissor_mismatch    := cmd.scissor         != is_scissor;
		rendermode_mismatch := cmd.rendermode      != current_rendermode;
		if shader_mismatch || texture_mismatch || scissor_mismatch || rendermode_mismatch {
			draw_vertex_list(im_queued_for_drawing[:], current_shader, current_texture);
			clear(&im_queued_for_drawing);
		}

		if shader_mismatch     do current_shader  = cmd.shader;
		if texture_mismatch    do current_texture = cmd.texture;
		if rendermode_mismatch {
			current_rendermode = cmd.rendermode;
			cmd.rendermode();
		}

		if scissor_mismatch {
			is_scissor = cmd.scissor;
			if is_scissor {
				gpu.scissor(cmd.scissor_rect);
			}
			else {
				gpu.unscissor(platform.current_window_width, platform.current_window_height);
			}
		}

		#complete
		switch kind in cmd.kind {
			case Draw_Quad_Command: {
				p1, p2, p3, p4 := kind.min, Vec2{kind.min.x, kind.max.y}, kind.max, Vec2{kind.max.x, kind.min.y};

				v1 := gpu.Vertex2D{p1, {}, kind.color};
				v2 := gpu.Vertex2D{p2, {}, kind.color};
				v3 := gpu.Vertex2D{p3, {}, kind.color};
				v4 := gpu.Vertex2D{p3, {}, kind.color};
				v5 := gpu.Vertex2D{p4, {}, kind.color};
				v6 := gpu.Vertex2D{p1, {}, kind.color};

				append(&im_queued_for_drawing, v1, v2, v3, v4, v5, v6);
			}
			case Draw_Sprite_Command: {
				p1, p2, p3, p4 := kind.min, Vec2{kind.min.x, kind.max.y}, kind.max, Vec2{kind.max.x, kind.min.y};

				v1 := gpu.Vertex2D{p1, kind.uvs[0], kind.color};
				v2 := gpu.Vertex2D{p2, kind.uvs[1], kind.color};
				v3 := gpu.Vertex2D{p3, kind.uvs[2], kind.color};
				v4 := gpu.Vertex2D{p3, kind.uvs[2], kind.color};
				v5 := gpu.Vertex2D{p4, kind.uvs[3], kind.color};
				v6 := gpu.Vertex2D{p1, kind.uvs[0], kind.color};

				append(&im_queued_for_drawing, v1, v2, v3, v4, v5, v6);
			}
			case Draw_Texture_Command: {
				unimplemented();
			}
			case: panic(tprint("unhandled case: ", kind));
		}
	}

	if len(im_queued_for_drawing) > 0 {
		draw_vertex_list(im_queued_for_drawing[:], current_shader, current_texture);
		clear(&im_queued_for_drawing);
	}
}

draw_vertex_list :: proc(list: []gpu.Vertex2D, shader: gpu.Shader_Program, texture: gpu.Texture, loc := #caller_location) {
	if len(list) == 0 {
		return;
	}

	when DEVELOPER {
		if debugging_rendering_max_draw_calls != -1 && num_draw_calls >= debugging_rendering_max_draw_calls {
			num_draw_calls += 1;
			return;
		}
	}

	gpu.update_mesh(&_internal_im_model, 0, list, []u32{});
	gpu.use_program(shader);
	gpu.draw_model(_internal_im_model, Vec3{}, Vec3{1, 1, 1}, Quat{0, 0, 0, 1}, texture, COLOR_WHITE, false, loc);
	num_draw_calls += 1;
}



debugging_rendering_max_draw_calls : i32 = -1; // note(josh): i32 because my dear-imgui stuff wasn't working with int
num_draw_calls: i32;
when DEVELOPER {
	debug_will_issue_next_draw_call :: proc() -> bool {
		return debugging_rendering_max_draw_calls == -1 || num_draw_calls < debugging_rendering_max_draw_calls;
	}
}



Draw_Command :: struct {
	render_order:  int,
	serial_number: int,

	rendermode:   gpu.Rendermode_Proc,
	shader:       gpu.Shader_Program,
	texture:      gpu.Texture,
	scissor:      bool,
	scissor_rect: [4]int,

	kind: union {
		Draw_Quad_Command,
		Draw_Texture_Command,
		Draw_Sprite_Command,
	},

}
Draw_Quad_Command :: struct {
	min, max: Vec2,
	color: Colorf,
}
Draw_Texture_Command :: struct {
	position: Vec2,
	scale: Vec2,
	color: Colorf,
}
Draw_Sprite_Command :: struct {
	min, max: Vec2,
	color: Colorf,
	uvs: [4]Vec2,
}