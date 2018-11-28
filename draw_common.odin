package workbench

using import        "core:math"
using import        "core:fmt"
      import        "core:sort"
      import        "core:strings"
      import        "core:mem"
      import        "core:os"

      import odingl "external/gl"

      import        "external/stb"
      import        "external/glfw"
      import        "external/imgui"



mvp_matrix: Mat4;

model_matrix: Mat4;

perspective_projection_matrix: Mat4;
orthographic_projection_matrix: Mat4;

unit_to_pixel_matrix:  Mat4;
unit_to_viewport_matrix:  Mat4;

pixel_to_world_matrix: Mat4;
pixel_to_viewport_matrix: Mat4;

viewport_to_pixel_matrix: Mat4;
viewport_to_unit_matrix:  Mat4;

world_to_viewport :: inline proc(position: Vec3) -> Vec3 {
	if current_camera.is_perspective {
		mv := mul(perspective_projection_matrix, current_camera.view_matrix);
		result := mul(mv, Vec4{position.x, position.y, position.z, 1});
		if result.w > 0 do result /= result.w;
		new_result := Vec3{result.x, result.y, result.z};
		return new_result;
	}

	result := mul(orthographic_projection_matrix, Vec4{position.x, position.y, position.z, 1});
	return Vec3{result.x, result.y, result.z};
}
world_to_pixel :: inline proc(a: Vec3) -> Vec3 {
	result := world_to_viewport(a);
	result = viewport_to_pixel(result);
	return result;
}
world_to_unit :: inline proc(a: Vec3) -> Vec3 {
	result := world_to_viewport(a);
	result = viewport_to_unit(result);
	return result;
}

unit_to_pixel :: inline proc(a: Vec3) -> Vec3 {
	result := a * Vec3{current_window_width, current_window_height, 1};
	return result;
}
unit_to_viewport :: inline proc(a: Vec3) -> Vec3 {
	result := (a * 2) - Vec3{1, 1, 0};
	return result;
}

pixel_to_viewport :: inline proc(a: Vec3) -> Vec3 {
	a /= Vec3{current_window_width/2, current_window_height/2, 1};
	a -= Vec3{1, 1, 0};
	return a;
}
pixel_to_unit :: inline proc(a: Vec3) -> Vec3 {
	a /= Vec3{current_window_width, current_window_height, 1};
	return a;
}

viewport_to_pixel :: inline proc(a: Vec3) -> Vec3 {
	a += Vec3{1, 1, 0};
	a *= Vec3{current_window_width/2, current_window_height/2, 0};
	a.z = 0;
	return a;
}
viewport_to_unit :: inline proc(a: Vec3) -> Vec3 {
	a += Vec3{1, 1, 0};
	a /= 2;
	a.z = 0;
	return a;
}



Camera :: struct {
	is_perspective: bool,
	// orthographic -> size in world units from center of screen to top of screen
	// perspective  -> fov
	size: f32,

	position: Vec3,
	rotation: Vec3,

	view_matrix: Mat4,
}

current_camera: ^Camera;

set_current_camera :: proc(camera: ^Camera) {
	current_camera = camera;
}

update_view_matrix :: proc(using camera: ^Camera) {
	normalize_camera_rotation(camera);

	view_matrix = identity(Mat4);
	view_matrix = translate(view_matrix, Vec3{-position.x, -position.y, -position.z});

	qx := axis_angle(Vec3{1,0,0}, to_radians(360 - rotation.x));
	qy := axis_angle(Vec3{0,1,0}, to_radians(360 - rotation.y));
	// todo(josh): z axis
	// qz := axis_angle(Vec3{0,0,1}, to_radians(360 - rotation.z));
	orientation := quat_mul(qx, qy);
	orientation = quat_norm(orientation);
	rotation_matrix := quat_to_mat4(orientation);
	view_matrix = mul(rotation_matrix, view_matrix);
}

camera_up      :: inline proc(using camera: ^Camera) -> Vec3 do return quaternion_up     (degrees_to_quaternion(rotation));
camera_down    :: inline proc(using camera: ^Camera) -> Vec3 do return quaternion_down   (degrees_to_quaternion(rotation));
camera_left    :: inline proc(using camera: ^Camera) -> Vec3 do return quaternion_left   (degrees_to_quaternion(rotation));
camera_right   :: inline proc(using camera: ^Camera) -> Vec3 do return quaternion_right  (degrees_to_quaternion(rotation));
camera_forward :: inline proc(using camera: ^Camera) -> Vec3 do return quaternion_forward(degrees_to_quaternion(rotation));
camera_back    :: inline proc(using camera: ^Camera) -> Vec3 do return quaternion_back   (degrees_to_quaternion(rotation));

get_cursor_direction_from_camera :: proc(camera: ^Camera) -> Vec3 {
	cursor_viewport_position := to_vec4((cursor_unit_position * 2) - Vec2{1, 1});
	cursor_viewport_position.w = 1;
	cursor_viewport_position.z = 0.5; // just some way down the frustum

	inv := _mat4_inverse(mul(perspective_projection_matrix, current_camera.view_matrix));
	cursor_world_position4 := mul(inv, cursor_viewport_position);
	if cursor_world_position4.w != 0 do cursor_world_position4 /= cursor_world_position4.w;
	cursor_world_position := to_vec3(cursor_world_position4) - camera.position;
	cursor_direction := norm(cursor_world_position);

	return cursor_direction;
}

normalize_camera_rotation :: proc(using camera: ^Camera) {
	for _, i in rotation {
		element := &rotation[i];
		for element^ < 0   do element^ += 360;
		for element^ > 360 do element^ -= 360;
	}
}

//
// Debug
//

Line_Segment :: struct {
	a, b: Vec3,
	color: Colorf,
	rendermode: Rendermode_Proc,
}

debug_vertices: [dynamic]Buffered_Vertex;

push_debug_vertex :: inline proc(rendermode: Rendermode_Proc, a: Vec3, color: Colorf) {
	v := Buffered_Vertex{0, len(debug_vertices), a, {}, color, rendermode, shader_rgba, {}, false, full_screen_scissor_rect()};
	append(&debug_vertices, v);
}

push_debug_line :: inline proc(rendermode: Rendermode_Proc, a, b: Vec3, color: Colorf) {
	push_debug_vertex(rendermode, a, color);
	push_debug_vertex(rendermode, b, color);
}

push_debug_box :: proc[push_debug_box_min_max, push_debug_box_points];
push_debug_box_min_max :: inline proc(rendermode: Rendermode_Proc, min, max: Vec3, color: Colorf) {
	push_debug_line(rendermode, Vec3{min.x, min.y, min.z}, Vec3{min.x, max.y, max.z}, color);
	push_debug_line(rendermode, Vec3{min.x, max.y, max.z}, Vec3{max.x, max.y, max.z}, color);
	push_debug_line(rendermode, Vec3{max.x, max.y, max.z}, Vec3{max.x, min.y, min.z}, color);
	push_debug_line(rendermode, Vec3{max.x, min.y, min.z}, Vec3{min.x, min.y, min.z}, color);
}
push_debug_box_points :: inline proc(rendermode: Rendermode_Proc, a, b, c, d: Vec3, color: Colorf) {
	push_debug_line(rendermode, a, b, color);
	push_debug_line(rendermode, b, c, color);
	push_debug_line(rendermode, c, d, color);
	push_debug_line(rendermode, d, a, color);
}

draw_debug_lines :: inline proc() {
	assert(len(debug_vertices) % 2 == 0);
	depth_test := odingl.IsEnabled(odingl.DEPTH_TEST);
	odingl.Disable(odingl.DEPTH_TEST);
	im_draw_flush(odingl.LINES, debug_vertices[:]);
	if depth_test == odingl.TRUE {
		odingl.Enable(odingl.DEPTH_TEST);
	}
}



_clear_render_buffers :: proc() {
	clear(&debug_vertices);
	clear(&im_buffered_verts);
}

_prerender :: proc() {
	log_gl_errors(#procedure);

	odingl.Enable(odingl.BLEND);
	odingl.BlendFunc(odingl.SRC_ALPHA, odingl.ONE_MINUS_SRC_ALPHA);
	if current_camera.is_perspective {
		// odingl.Enable(odingl.CULL_FACE);
		odingl.Enable(odingl.DEPTH_TEST); // note(josh): @DepthTest: fucks with the sorting of 2D stuff because all Z is 0 :/
		odingl.Clear(odingl.COLOR_BUFFER_BIT | odingl.DEPTH_BUFFER_BIT); // note(josh): @DepthTest: DEPTH stuff fucks with 2D sorting because all Z is 0.
	}
	else {
		odingl.Disable(odingl.DEPTH_TEST); // note(josh): @DepthTest: fucks with the sorting of 2D stuff because all Z is 0 :/
		odingl.Clear(odingl.COLOR_BUFFER_BIT);
	}

	odingl.Viewport(0, 0, cast(i32)current_window_width, cast(i32)current_window_height);

	log_gl_errors(#procedure);
}

render_workspace :: proc(workspace: Workspace) {
	log_gl_errors(#procedure);

	num_draw_calls = 0;
	if workspace.render != nil {
		workspace.render(fixed_delta_time);
	}

	_prerender();

	flush_3d();
	im_draw_flush(odingl.TRIANGLES, im_buffered_verts[:]);
	draw_debug_lines();
	imgui_render(true);

	log_gl_errors(tprint("workspace_name: ", workspace.name));
}
