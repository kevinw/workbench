package workbench

import "core:fmt"
import "core:sort"
import "core:strings"
import "core:mem"
import rt "core:runtime"
import "core:os"

import "platform"
import "profiler"
import "gpu"
import "logging"

import "external/stb"
import "external/glfw"
import "external/imgui"

/*

--- Cameras
{
	init_camera                 :: proc(camera: ^Camera, is_perspective: bool, size: f32, pixel_width, pixel_height: int, make_framebuffer := false)
	delete_camera               :: proc(camera: Camera)
	PUSH_CAMERA                 :: proc(camera: ^Camera) -> ^Camera
	push_camera_non_deferred    :: proc(camera: ^Camera) -> ^Camera
	pop_camera                  :: proc(old_camera: ^Camera)
	camera_prerender            :: proc(camera: ^Camera)
	update_camera_pixel_size    :: proc(using camera: ^Camera, new_width: f32, new_height: f32)
	construct_view_matrix       :: proc(camera: ^Camera) -> Mat4
	construct_projection_matrix :: proc(camera: ^Camera) -> Mat4
	construct_rendermode_matrix :: proc(camera: ^Camera) -> Mat4
}

--- Textures
{
	create_texture        :: proc(w, h: int, gpu_format: gpu.Internal_Color_Format, pixel_format: gpu.Pixel_Data_Format, element_type: gpu.Texture2D_Data_Type, initial_data: ^u8 = nil, texture_target := gpu.Texture_Target.Texture2D) -> Texture
	delete_texture        :: proc(texture: Texture)
	draw_texture          :: proc(texture: Texture, pixel1: Vec2, pixel2: Vec2, color := Colorf{1, 1, 1, 1})
	write_texture_to_file :: proc(filepath: string, texture: Texture)
}

--- Framebuffers
{
	default_framebuffer_settings :: proc() -> Framebuffer_Settings
	create_framebuffer     :: proc(width, height: int) -> Framebuffer
	delete_framebuffer           :: proc(framebuffer: Framebuffer)
}

--- Models
{
	add_mesh_to_model      :: proc(model: ^Model, vertices: []$Vertex_Type, indices: []u32) -> int
	remove_mesh_from_model :: proc(model: ^Model, idx: int)
	update_mesh            :: proc(model: ^Model, idx: int, vertices: []$Vertex_Type, indices: []u32)
	delete_model           :: proc(model: Model)
	draw_model             :: proc(model: Model, position: Vec3, scale: Vec3, rotation: Quat, texture: Texture, color: Colorf, depth_test: bool)
}

--- Rendermodes
{
	rendermode_world :: proc()
	rendermode_unit  :: proc()
	rendermode_pixel :: proc()
}

--- Helpers
{
	create_cube_model :: proc() -> Model
	create_quad_model :: proc() -> Model

	get_mouse_world_position        :: proc(camera: ^Camera, cursor_unit_position: Vec2) -> Vec3
	get_mouse_direction_from_camera :: proc(camera: ^Camera, cursor_unit_position: Vec2) -> Vec3

	world_to_viewport :: proc(position: Vec3, camera: ^Camera) -> Vec3
	world_to_pixel    :: proc(a: Vec3, camera: ^Camera, pixel_width: f32, pixel_height: f32) -> Vec3
	world_to_unit     :: proc(a: Vec3, camera: ^Camera) -> Vec3

	unit_to_pixel    :: proc(a: Vec3, pixel_width: f32, pixel_height: f32) -> Vec3
	unit_to_viewport :: proc(a: Vec3) -> Vec3

	pixel_to_viewport :: proc(a: Vec3, pixel_width: f32, pixel_height: f32) -> Vec3
	pixel_to_unit     :: proc(a: Vec3, pixel_width: f32, pixel_height: f32) -> Vec3

	viewport_to_pixel :: proc(a: Vec3, pixel_width: f32, pixel_height: f32) -> Vec3
	viewport_to_unit  :: proc(a: Vec3) -> Vec3
}

*/

current_camera: ^Camera;
current_framebuffer: Framebuffer;

//
// Camera
//

// todo(josh): why are these defined in gpu? move them here if possible
Model :: gpu.Model;
Mesh :: gpu.Mesh;
Skinned_Mesh :: gpu.Skinned_Mesh;
Vertex2D :: gpu.Vertex2D;
Vertex3D :: gpu.Vertex3D;
Bone :: gpu.Bone;

Camera :: struct {
    is_perspective: bool,

    // orthographic -> size in world units from center of screen to top of screen
    // perspective  -> fov
    size: f32,

    near_plane: f32,
    far_plane:  f32,

    clear_color: Colorf,

    position: Vec3,
    rotation: Quat,

    pixel_width: f32,
    pixel_height: f32,
    aspect: f32,

    framebuffer: Framebuffer,
    bloom_ping_pong_framebuffers: Maybe([2]Framebuffer),

    current_rendermode: Rendermode,
    draw_mode: gpu.Draw_Mode,
    polygon_mode: gpu.Polygon_Mode,


    // render data for this frame
	render_queue: [dynamic]Model_Draw_Info,

	// todo(josh): maybe these should be pointers. this is blowing up the size of the camera struct a LOT
	point_light_positions:   [MAX_LIGHTS]Vec3,
	point_light_colors:      [MAX_LIGHTS]Vec4,
	point_light_intensities: [MAX_LIGHTS]f32,
	num_point_lights: i32,

	sun_direction: Vec3,
	sun_color:     Vec4,
	sun_intensity: f32,
	sun_rotation:  Quat,
	shadow_map_cameras: Maybe([NUM_SHADOW_MAPS]^Camera),

	auto_resize_framebuffer: bool,
}

MAX_LIGHTS :: 100;
NUM_SHADOW_MAPS :: 4;
SHADOW_MAP_DIM :: 2048;

Model_Draw_Info :: struct {
	model: Model,
	shader: gpu.Shader_Program,
	texture: Texture,
	material: Material,
	position: Vec3,
	scale: Vec3,
	rotation: Quat,
	color: Colorf,
	animation_state: Model_Animation_State,

	userdata: rawptr,
}

Model_Animation_State :: struct {
	// todo(josh): free mesh_states. we probably shouldn't be storing dynamic memory on Model_Draw_Info because we churn through a _lot_ of these per frame, array of bones could probably be capped at 4 or 8 or something
	mesh_states: [dynamic]Mesh_State // array of bones per mesh in the model
}

Mesh_State :: struct {
	state : [dynamic]Mat4
}

init_camera :: proc(camera: ^Camera, is_perspective: bool, size: f32, pixel_width, pixel_height: int, framebuffer := Framebuffer{}) {
    camera.is_perspective = is_perspective;
    camera.size = size;
    camera.near_plane = 0.01;
    camera.far_plane = 1000;
    camera.position = Vec3{};
    camera.rotation = Quat{0, 0, 0, 1};
    camera.draw_mode = .Triangles;
    camera.polygon_mode = .Fill;
    camera.clear_color = {0, 0, 0, 1};
    camera.pixel_width = cast(f32)pixel_width;
    camera.pixel_height = cast(f32)pixel_height;
    camera.aspect = camera.pixel_width / camera.pixel_height;

    assert(camera.framebuffer.fbo == 0);
    camera.framebuffer = framebuffer;
}

delete_camera :: proc(camera: ^Camera) { // note(josh): does NOT free the camera you pass in
    if camera.framebuffer.fbo != 0 {
        delete_framebuffer(camera.framebuffer);
    }
    destroy_bloom(camera);
    destroy_shadow_maps(camera);
    delete(camera.render_queue);
}

setup_bloom :: proc(camera: ^Camera) {
	assert(camera.bloom_ping_pong_framebuffers == nil);

	fbos: [2]Framebuffer;
	for _, idx in fbos {
		// todo(josh): apparently these should use Linear and Clamp_To_Border, not Nearest and Repeat as is hardcoded in create_framebuffer
		fbos[idx] = create_framebuffer(cast(int)camera.pixel_width, cast(int)camera.pixel_height, 1);
	}
	camera.bloom_ping_pong_framebuffers = fbos;
}
destroy_bloom :: proc(camera: ^Camera) {
	if fbos, ok := getval(camera.bloom_ping_pong_framebuffers); ok {
    	for fbo in fbos do delete_framebuffer(fbo);
    }
}

setup_shadow_maps :: proc(camera: ^Camera) {
	assert(camera.shadow_map_cameras == nil);

	shadow_maps: [NUM_SHADOW_MAPS]^Camera;
	for idx in 0..<NUM_SHADOW_MAPS {
		cascade_camera := new(Camera);
		init_camera(cascade_camera, false, 10, SHADOW_MAP_DIM, SHADOW_MAP_DIM, create_framebuffer(SHADOW_MAP_DIM, SHADOW_MAP_DIM, 0));
		cascade_camera.near_plane = 0.01;
		cascade_camera.clear_color = {1, 1, 1, 1}; // todo(josh): what the heck should this be?
		shadow_maps[idx] = cascade_camera;
	}
	camera.shadow_map_cameras = shadow_maps;
}
destroy_shadow_maps :: proc(camera: ^Camera) {
	if shadow_maps, ok := getval(camera.shadow_map_cameras); ok {
		for cascade_camera in shadow_maps {
	    	if cascade_camera != nil {
	    		delete_camera(cascade_camera);
	    		free(cascade_camera);
	    	}
	    }
	}
}

@(deferred_out=pop_camera)
PUSH_CAMERA :: proc(camera: ^Camera) -> ^Camera {
	return push_camera_non_deferred(camera);
}

push_camera_non_deferred :: proc(camera: ^Camera) -> ^Camera {
	old_camera := current_camera;
	current_camera = camera;

	if camera.auto_resize_framebuffer {
		update_camera_pixel_size(camera, platform.current_window_width, platform.current_window_height);
	}

	push_framebuffer_non_deferred(camera.framebuffer);

	gpu.enable(gpu.Capabilities.Blend);
	gpu.blend_func(.Src_Alpha, .One_Minus_Src_Alpha);

	gpu.set_clear_color(camera.clear_color);
	gpu.clear_screen(.Color_Buffer | .Depth_Buffer);

	return old_camera;
}

pop_camera :: proc(old_camera: ^Camera) {
	current_camera = old_camera;

	if current_camera != nil {
		gpu.viewport(0, 0, cast(int)current_camera.pixel_width, cast(int)current_camera.pixel_height);
		pop_framebuffer(current_camera.framebuffer);
	}
	else {
		pop_framebuffer({});
	}
}



update_camera_pixel_size :: proc(using camera: ^Camera, new_width: f32, new_height: f32) {
    pixel_width = new_width;
    pixel_height = new_height;
    aspect = new_width / new_height;

    if framebuffer.fbo != 0 {
        if framebuffer.width != cast(int)new_width || framebuffer.height != cast(int)new_height {
            logging.ln("Rebuilding framebuffer...");

        	num_color_buffers := len(framebuffer.attachments);
            delete_framebuffer(framebuffer);
            framebuffer = create_framebuffer(cast(int)new_width, cast(int)new_height, num_color_buffers);
        }
    }
}

// todo(josh): it's probably slow that we dont cache matrices at all :grimacing:
construct_view_matrix :: proc(camera: ^Camera) -> Mat4 {
	if camera.current_rendermode != .World {
		return identity(Mat4);
	}

	view_matrix := translate(identity(Mat4), -camera.position);
	rotation := camera.rotation;
    rotation_matrix := quat_to_mat4(inverse(rotation));
    view_matrix = mul(rotation_matrix, view_matrix);
    return view_matrix;
}

construct_projection_matrix :: proc(camera: ^Camera) -> Mat4 {
    if camera.is_perspective {
        return perspective(to_radians(camera.size), camera.aspect, camera.near_plane, camera.far_plane);
    }
    else {
        top    : f32 =  1 * camera.size;
        bottom : f32 = -1 * camera.size;
        left   : f32 = -1 * camera.aspect * camera.size;
        right  : f32 =  1 * camera.aspect * camera.size;
        return ortho3d(left, right, bottom, top, camera.near_plane, camera.far_plane);
    }
}

construct_rendermode_matrix :: proc(camera: ^Camera) -> Mat4 {
    switch camera.current_rendermode {
        case .World: {
            return construct_projection_matrix(camera);
        }
        case .Unit: {
            unit := translate(identity(Mat4), Vec3{-1, -1, 0});
            unit = mat4_scale(unit, 2);
            return unit;
        }
        case .Pixel: {
            pixel := mat4_scale(identity(Mat4), Vec3{1.0 / camera.pixel_width, 1.0 / camera.pixel_height, 0});
            pixel = mat4_scale(pixel, 2);
            pixel = translate(pixel, Vec3{-1, -1, 0});
            return pixel;
        }
        case: panic(tprint(camera.current_rendermode));
    }

    unreachable();
    return {};
}

camera_render :: proc(camera: ^Camera, user_render_proc: proc(f32)) {
	profiler.TIMED_SECTION(&wb_profiler, "camera_render");

	// pre-render
	gpu.log_errors(#procedure);
	PUSH_CAMERA(camera);

	if user_render_proc != nil {
		user_render_proc(lossy_delta_time);
		gpu.log_errors(#procedure);
	}

	// draw shadow maps
	if shadow_maps, ok := getval(camera.shadow_map_cameras); ok {
		draw_shadow_maps(camera, shadow_maps);
	}

	// draw scene for real
	PUSH_RENDERMODE(.World);

	for info in camera.render_queue {
		using info;

		gpu.use_program(shader);


		// flush lights to gpu
		if camera.num_point_lights > 0 {
			gpu.uniform_vec3_array(shader,  "point_light_positions",   camera.point_light_positions[:camera.num_point_lights]);
			gpu.uniform_vec4_array(shader,  "point_light_colors",      camera.point_light_colors[:camera.num_point_lights]);
			gpu.uniform_float_array(shader, "point_light_intensities", camera.point_light_intensities[:camera.num_point_lights]);
		}
		gpu.uniform_int(shader, "num_point_lights", camera.num_point_lights);

		if len(camera.sun_direction) > 0 {
			gpu.uniform_vec3(shader,  "sun_direction", camera.sun_direction);
			gpu.uniform_vec4(shader,  "sun_color",     camera.sun_color);
			gpu.uniform_float(shader, "sun_intensity", camera.sun_intensity);
		}

		if shadow_maps, ok := getval(camera.shadow_map_cameras); ok {
			// set up cascade cameras
			gpu.uniform_float_array(shader, "cascade_distances", shadow_cascade_positions[1:]);

			assert(NUM_SHADOW_MAPS == 4);
			tex_indices := [NUM_SHADOW_MAPS]i32{1, 2, 3, 4};
			gpu.uniform_int_array(shader, "shadow_maps", tex_indices[:]);
			light_matrices: [NUM_SHADOW_MAPS]Mat4;
			for shadow_map, map_idx in shadow_maps {
				// todo(josh): this texture binding stuff makes me a little uncomfortable because
				// draw_model does some texture binding too and I fear it might stomp on these ones
				// in the future. should consolidate this somehow
				gpu.active_texture(1 + cast(u32)map_idx);
				gpu.bind_texture_2d(shadow_map.framebuffer.depth_texture.gpu_id);

				light_view := construct_view_matrix(shadow_map);
				light_proj := construct_projection_matrix(shadow_map);
				light_space := mul(light_proj, light_view);
				light_matrices[map_idx] = light_space;
			}
			gpu.uniform_mat4_array(shader, "cascade_light_space_matrices", light_matrices[:]);
		}



		// set material data
		gpu.uniform_vec4 (shader, "material.ambient",  transmute(Vec4)material.ambient);
		gpu.uniform_vec4 (shader, "material.diffuse",  transmute(Vec4)material.diffuse);
		gpu.uniform_vec4 (shader, "material.specular", transmute(Vec4)material.specular);
		gpu.uniform_float(shader, "material.shine",    material.shine);


		// issue draw call
		if on_render_object != nil do on_render_object(userdata);
		draw_model(model, position, scale, rotation, texture, color, true, animation_state);
	}

	// todo(josh): ambient occlusion

	if post_render_proc != nil {
		post_render_proc();
	}

	// do bloom
	if bloom_fbos, ok := getval(camera.bloom_ping_pong_framebuffers); ok {
		for fbo in bloom_fbos {
			PUSH_FRAMEBUFFER(fbo);
			gpu.clear_screen(.Color_Buffer | .Depth_Buffer);
		}

		horizontal := true;
		first := true;
		amount := 5;
		last_bloom_fbo: Maybe(Framebuffer);
		shader_blur := get_shader(&wb_catalog, "blur");
		gpu.use_program(shader_blur);
		for i in 0..<amount {
			PUSH_FRAMEBUFFER(bloom_fbos[cast(int)horizontal]);
			gpu.uniform_int(shader_blur, "horizontal", cast(i32)horizontal);
			if first {
				draw_texture(camera.framebuffer.textures[1], {0, 0}, {1, 1});
			}
			else {
				bloom_fbo := bloom_fbos[cast(int)(!horizontal)];
				draw_texture(bloom_fbo.textures[0], {0, 0}, {1, 1});
				last_bloom_fbo = bloom_fbo;
			}
			horizontal = !horizontal;
			first = false;
		}

		if last_bloom_fbo, ok := getval(last_bloom_fbo); ok {
			shader_bloom := get_shader(&wb_catalog, "bloom");
			gpu.use_program(shader_bloom);
			gpu.uniform_int(shader_bloom, "bloom_texture", 1);
			gpu.active_texture1();
			gpu.bind_texture_2d(last_bloom_fbo.textures[0].gpu_id);
			draw_texture(camera.framebuffer.textures[0], {0, 0}, {1, 1});

			if render_settings.visualize_bloom_texture {
				gpu.use_program(get_shader(&wb_catalog, "default"));
				draw_texture(last_bloom_fbo.textures[0], {256, 0} / platform.current_window_size, {512, 256} / platform.current_window_size);
			}
		}
	}

	// todo(josh): should this be before bloom?
	im_flush();

	debug_geo_flush();

	// visualize depth buffer
	if render_settings.visualize_shadow_texture {
		if shadow_maps, ok := getval(camera.shadow_map_cameras); ok {
			if length(camera.sun_direction) > 0 {
				gpu.use_program(get_shader(&wb_catalog, "depth"));
				for shadow_map, map_idx in shadow_maps {
					draw_texture(shadow_map.framebuffer.depth_texture, {256 * cast(f32)map_idx, 0} / platform.current_window_size, {256 * (cast(f32)map_idx+1), 256} / platform.current_window_size);
				}
			}
		}
	}


	// clear render_queue
	clear(&camera.render_queue);

	// clear lights
	camera.num_point_lights = 0;

	if done_postprocessing_proc != nil {
		done_postprocessing_proc();
	}
}

shadow_cascade_positions := [NUM_SHADOW_MAPS+1]f32{0, 20, 40, 150, 1000};

draw_shadow_maps :: proc(main_camera: ^Camera, shadow_map_cameras: [NUM_SHADOW_MAPS]^Camera) {
	for shadow_map_camera, map_idx in shadow_map_cameras {
		assert(shadow_map_camera != nil);

		frustum_corners := [8]Vec3 {
			{-1,  1, -1},
			{ 1,  1, -1},
			{ 1, -1, -1},
			{-1, -1, -1},
			{-1,  1,  1},
			{ 1,  1,  1},
			{ 1, -1,  1},
			{-1, -1,  1},
		};



		// calculate sub-frustum for this cascade
		cascade_proj := perspective(to_radians(main_camera.size), main_camera.aspect, main_camera.near_plane + shadow_cascade_positions[map_idx], min(main_camera.far_plane, main_camera.near_plane + shadow_cascade_positions[map_idx+1]));
		cascade_view := construct_view_matrix(main_camera);
		cascade_viewport_to_world := mat4_inverse(mul(cascade_proj, cascade_view));

		transform_point :: proc(matrix: Mat4, pos: Vec3) -> Vec3 {
			pos4 := to_vec4(pos);
			pos4.w = 1;
			pos4 = mul(matrix, pos4);
			if pos4.w != 0 do pos4 /= pos4.w;
			return to_vec3(pos4);
		}



		// calculate center point and radius of frustum
		center_point: Vec3;
		for _, idx in frustum_corners {
			frustum_corners[idx] = transform_point(cascade_viewport_to_world, frustum_corners[idx]);
			center_point += frustum_corners[idx];
		}
		center_point /= len(frustum_corners);



		// todo(josh): this radius changes very slightly as the camera rotates around for some reason. this shouldn't be happening and I believe it's causing the flickering
		// todo(josh): this radius changes very slightly as the camera rotates around for some reason. this shouldn't be happening and I believe it's causing the flickering
		// todo(josh): this radius changes very slightly as the camera rotates around for some reason. this shouldn't be happening and I believe it's causing the flickering
		// note(josh): hacked around the problem by clamping the radius to an int. pretty shitty, should investigate a proper solution
		radius := cast(f32)cast(int)(length(frustum_corners[0] - frustum_corners[6]) / 2 + 1.0);



		light_rotation := main_camera.sun_rotation;
		light_direction := quaternion_forward(light_rotation);

		texels_per_unit := SHADOW_MAP_DIM / (radius * 2);
		scale_matrix := identity(Mat4);
		scale_matrix = mat4_scale(scale_matrix, Vec3{texels_per_unit, texels_per_unit, texels_per_unit});
		scale_matrix = mul(scale_matrix, quat_to_mat4(inverse(light_rotation)));

		// draw_debug_box(center_point, Vec3{1/texels_per_unit, 1/texels_per_unit, 1/texels_per_unit}, COLOR_RED, light_rotation);
		center_point_texel_space := transform_point(scale_matrix, center_point);
		center_point_texel_space.x = round(center_point_texel_space.x);
		center_point_texel_space.y = round(center_point_texel_space.y);
		center_point_texel_space.z = round(center_point_texel_space.z);
		center_point = transform_point(mat4_inverse(scale_matrix), center_point_texel_space);
		// if map_idx == 0 do draw_debug_box(center_point, Vec3{1/texels_per_unit, 1/texels_per_unit, 1/texels_per_unit}, COLOR_GREEN, light_rotation, false);


		// position the shadow camera looking at that point
		shadow_map_camera.position = center_point - light_direction * radius;
		shadow_map_camera.rotation = light_rotation;
		shadow_map_camera.size = radius;
		shadow_map_camera.far_plane = radius * 2;

		// render scene from perspective of sun
		PUSH_CAMERA(shadow_map_camera);

		depth_shader := get_shader(&wb_catalog, "shadow");
		gpu.use_program(depth_shader);

		PUSH_RENDERMODE(.World);

		for info in main_camera.render_queue {
			using info;

			if on_render_object != nil do on_render_object(userdata);
			draw_model(model, position, scale, rotation, texture, color, true, animation_state);
		}
	}
}



Material :: struct {
	ambient:  Colorf,
	diffuse:  Colorf,
	specular: Colorf,
	shine:    f32,
}

submit_model :: proc(model: Model, shader: gpu.Shader_Program, texture: Texture, material: Material, position: Vec3, scale: Vec3, rotation: Quat, color: Colorf, anim_state: Model_Animation_State, userdata : rawptr = {}) {
	append(&current_camera.render_queue, Model_Draw_Info{model, shader, texture, material, position, scale, rotation, color, anim_state, userdata});
}
push_point_light :: proc(position: Vec3, color: Colorf, intensity: f32) {
	if current_camera.num_point_lights >= MAX_LIGHTS {
		logging.ln("Too many lights! The max is ", MAX_LIGHTS);
		return;
	}

	current_camera.point_light_positions  [current_camera.num_point_lights] = position;
	current_camera.point_light_colors     [current_camera.num_point_lights] = transmute(Vec4)color;
	current_camera.point_light_intensities[current_camera.num_point_lights] = intensity;
	current_camera.num_point_lights += 1;
}

set_sun_data :: proc(rotation: Quat, color: Colorf, intensity: f32) {
	current_camera.sun_direction  = quaternion_forward(rotation);
	current_camera.sun_color      = transmute(Vec4)color;
	current_camera.sun_intensity  = intensity;
	current_camera.sun_rotation   = rotation;
}



//
// Textures
//

Texture :: struct {
    gpu_id: gpu.TextureId,

    width, height, depth: int,

    target: gpu.Texture_Target,
    format: gpu.Pixel_Data_Format,
    element_type: gpu.Texture2D_Data_Type,
}

create_texture_2d :: proc(ww, hh: int, gpu_format: gpu.Internal_Color_Format, initial_data_format: gpu.Pixel_Data_Format, initial_data_element_type: gpu.Texture2D_Data_Type, initial_data: ^u8 = nil) -> Texture {
	texture := gpu.gen_texture();
	gpu.bind_texture_2d(texture);

	gpu.tex_image_2d(0, gpu_format, cast(i32)ww, cast(i32)hh, 0, initial_data_format, initial_data_element_type, initial_data);
	gpu.tex_parameteri(.Texture2D, .Mag_Filter, .Nearest);
	gpu.tex_parameteri(.Texture2D, .Min_Filter, .Nearest);

	return Texture{texture, ww, hh, 1, .Texture2D, initial_data_format, initial_data_element_type};
}

create_texture_3d :: proc(ww, hh, dd: int, gpu_format: gpu.Internal_Color_Format, initial_data_format: gpu.Pixel_Data_Format, initial_data_element_type: gpu.Texture2D_Data_Type, initial_data: ^u8 = nil) -> Texture {
	texture := gpu.gen_texture();
	gpu.bind_texture_3d(texture);
	gpu.tex_image_3d(0, gpu_format, cast(i32)ww, cast(i32)hh, cast(i32)dd, 0, initial_data_format, initial_data_element_type, initial_data);
	gpu.tex_parameteri(.Texture3D, .Min_Filter, .Linear);
	gpu.tex_parameteri(.Texture3D, .Min_Filter, .Linear);
	gpu.tex_parameteri(.Texture3D, .Wrap_S, .Repeat);
	gpu.tex_parameteri(.Texture3D, .Wrap_T, .Repeat);
	gpu.tex_parameteri(.Texture3D, .Wrap_R, .Repeat);

	return Texture{texture, ww, hh, dd, .Texture3D, initial_data_format, initial_data_element_type};
}

delete_texture :: proc(texture: Texture) {
	gpu.delete_texture(texture.gpu_id);
}

draw_texture :: proc(texture: Texture, unit0: Vec2, unit1: Vec2, color := Colorf{1, 1, 1, 1}) {
	PUSH_RENDERMODE(.Unit);
	center := to_vec3(lerp(unit0, unit1, f32(0.5)));
	size   := to_vec3(unit1 - unit0);
	draw_model(wb_quad_model, center, size, {0, 0, 0, 1}, texture, color, false);
}

bind_texture :: proc(texture: Texture) {
	#partial
	switch texture.target {
		case .Texture2D: gpu.bind_texture_2d(texture.gpu_id); // todo(josh): handle multiple textures per model
		case .Texture3D: gpu.bind_texture_3d(texture.gpu_id); // todo(josh): handle multiple textures per model
		case cast(gpu.Texture_Target)0: { } // todo(josh): should this be an error/warning?
		case: panic(tprint(texture.target));
	}
}

write_texture_to_file :: proc(filepath: string, texture: Texture) {
	assert(texture.target == .Texture2D, "Not sure if this is an error, delete this if it isn't");
	data := make([]u8, 4 * texture.width * texture.height);
	defer delete(data);
	gpu.bind_texture_2d(texture.gpu_id);
	gpu.get_tex_image(texture.target, .RGBA, .Unsigned_Byte, &data[0]);
	stb.write_png(filepath, texture.width, texture.height, 4, data, 4 * texture.width);
	gpu.log_errors(#procedure);
}



//
// Framebuffers
//

Framebuffer :: struct {
    fbo: gpu.FBO,
    textures: []Texture,
    depth_texture: Texture,

    width, height: int,
    attachments: []gpu.Framebuffer_Attachment,
}

create_framebuffer :: proc(width, height: int, num_color_buffers := 1, loc := #caller_location) -> Framebuffer {
	fbo := gpu.gen_framebuffer();
	gpu.bind_fbo(fbo);

	textures: [dynamic]Texture;
	attachments: [dynamic]gpu.Framebuffer_Attachment;
	assert(num_color_buffers <= 32, tprint(num_color_buffers, " is more than ", gpu.Framebuffer_Attachment.Color31));
	for buf_idx in 0..<num_color_buffers {
		texture := gpu.gen_texture();
		append(&textures, Texture{texture, width, height, 1, .Texture2D, .RGBA, .Unsigned_Byte});
		gpu.bind_texture_2d(texture);

		// todo(josh): is 16-bit float enough?
		gpu.tex_image_2d(0, .RGBA16F, cast(i32)width, cast(i32)height, 0, .RGBA, .Unsigned_Byte, nil);
		gpu.tex_parameteri(.Texture2D, .Mag_Filter, .Nearest);
		gpu.tex_parameteri(.Texture2D, .Min_Filter, .Nearest);
		gpu.tex_parameteri(.Texture2D, .Wrap_S, .Clamp_To_Border);
		gpu.tex_parameteri(.Texture2D, .Wrap_T, .Clamp_To_Border);

		attachment := cast(gpu.Framebuffer_Attachment)(cast(u32)gpu.Framebuffer_Attachment.Color0 + cast(u32)buf_idx);
		gpu.framebuffer_texture2d(cast(gpu.Framebuffer_Attachment)attachment, texture);

		append(&attachments, attachment);
	}

	depth_texture_id := gpu.gen_texture();
	gpu.bind_texture_2d(depth_texture_id);
	depth_texture := Texture{depth_texture_id, width, height, 1, .Texture2D, .Depth_Component, .Float};

	gpu.tex_image_2d(0, .Depth_Component, cast(i32)width, cast(i32)height, 0, .Depth_Component, .Float, nil);
	gpu.tex_parameteri(.Texture2D, .Mag_Filter, .Nearest);
	gpu.tex_parameteri(.Texture2D, .Min_Filter, .Nearest);
	gpu.tex_parameteri(.Texture2D, .Wrap_S, .Clamp_To_Border);
	gpu.tex_parameteri(.Texture2D, .Wrap_T, .Clamp_To_Border);
	c := Colorf{1, 1, 1, 1};
	gpu.tex_parameterfv(.Texture2D, .Texture_Border_Color, &c.r);

	gpu.framebuffer_texture2d(.Depth, depth_texture_id);

	if num_color_buffers > 0 {
		gpu.draw_buffers(attachments[:]);
	}
	else {
		gpu.draw_buffer(0);
		gpu.read_buffer(0);
	}



	gpu.assert_framebuffer_complete();
	gpu.bind_texture_2d(0);
	gpu.bind_rbo(0);
	gpu.bind_fbo(0);

	framebuffer := Framebuffer{fbo, textures[:], depth_texture, width, height, attachments[:]};
	return framebuffer;
}

delete_framebuffer :: proc(framebuffer: Framebuffer) {
	for t in framebuffer.textures {
		delete_texture(t);
	}
	delete_texture(framebuffer.depth_texture);
	delete(framebuffer.textures);
	delete(framebuffer.attachments);
	gpu.delete_fbo(framebuffer.fbo);
}

@(deferred_out=pop_framebuffer)
PUSH_FRAMEBUFFER :: proc(framebuffer: Framebuffer) -> Framebuffer {
	return push_framebuffer_non_deferred(framebuffer);
}

push_framebuffer_non_deferred :: proc(framebuffer: Framebuffer) -> Framebuffer {
	old := current_framebuffer;
	gpu.bind_fbo(framebuffer.fbo); // note(josh): can be 0
	current_framebuffer = framebuffer;
	gpu.viewport(0, 0, cast(int)framebuffer.width, cast(int)framebuffer.height);

	return old;
}

pop_framebuffer :: proc(old_framebuffer: Framebuffer) {
	gpu.bind_fbo(old_framebuffer.fbo); // note(josh): can be 0
	current_framebuffer = old_framebuffer;
	gpu.viewport(0, 0, cast(int)old_framebuffer.width, cast(int)old_framebuffer.height);
}

add_mesh_to_model :: proc(model: ^Model, vertices: []$Vertex_Type, indices: []u32, skin: Skinned_Mesh, loc := #caller_location) -> int {
	vao := gpu.gen_vao();
	vbo := gpu.gen_vbo();
	ibo := gpu.gen_ebo();

	idx := len(model.meshes);
	mesh := Mesh{vao, vbo, ibo, type_info_of(Vertex_Type), len(indices), len(vertices), skin};
	append(&model.meshes, mesh, loc);

	update_mesh(model, idx, vertices, indices);

	return idx;
}

remove_mesh_from_model :: proc(model: ^Model, idx: int, loc := #caller_location) {
	assert(idx < len(model.meshes));
	mesh := model.meshes[idx];
	_internal_delete_mesh(mesh, loc);
	unordered_remove(&model.meshes, idx);
}

update_mesh :: proc(model: ^Model, idx: int, vertices: []$Vertex_Type, indices: []u32) {
	assert(idx < len(model.meshes));
	mesh := &model.meshes[idx];

	gpu.bind_vao(mesh.vao);

	gpu.bind_vbo(mesh.vbo);
	gpu.buffer_vertices(vertices);

	gpu.bind_ibo(mesh.ibo);
	gpu.buffer_elements(indices);

	gpu.bind_vao(0);

	mesh.vertex_type  = type_info_of(Vertex_Type);
	mesh.index_count  = len(indices);
	mesh.vertex_count = len(vertices);
}

delete_model :: proc(model: Model, loc := #caller_location) {
	for mesh in model.meshes {
		_internal_delete_mesh(mesh, loc);
	}
	delete(model.meshes);
}

_internal_delete_mesh :: proc(mesh: Mesh, loc := #caller_location) {
	gpu.delete_vao(mesh.vao);
	gpu.delete_buffer(mesh.vbo);
	gpu.delete_buffer(mesh.ibo);
	gpu.log_errors(#procedure, loc);

	for name in mesh.skin.name_mapping {
		delete(name);
	}
	delete(mesh.skin.name_mapping);
	delete(mesh.skin.bones);
}

draw_model :: proc(model: Model,
				   position: Vec3,
				   scale: Vec3,
				   rotation: Quat,
				   texture: Texture,
				   color: Colorf,
				   depth_test: bool,
				   anim_state := Model_Animation_State{},
				   loc := #caller_location) {

	gpu.polygon_mode(.Front_And_Back, current_camera.polygon_mode);

	// projection matrix
	projection_matrix := construct_rendermode_matrix(current_camera);

	// view matrix
	view_matrix := construct_view_matrix(current_camera);

	// model_matrix
	model_p := translate(identity(Mat4), position);
	model_s := mat4_scale(identity(Mat4), scale);
	model_r := quat_to_mat4(rotation);
	model_matrix := mul(mul(model_p, model_r), model_s);

	// shader stuff
	program := gpu.get_current_shader();

	gpu.active_texture0();
	gpu.uniform_int(program, "texture_handle", 0);
	gpu.uniform_int(program, "has_texture", texture.gpu_id != 0 ? 1 : 0);

	gpu.uniform_vec3(program, "camera_position", current_camera.position);
	gpu.uniform_vec4(program, "mesh_color", transmute(Vec4)color);
	gpu.uniform_float(program, "bloom_threshhold", render_settings.bloom_threshhold);

	gpu.uniform_mat4(program, "model_matrix",      &model_matrix);
	gpu.uniform_mat4(program, "view_matrix",       &view_matrix);
	gpu.uniform_mat4(program, "projection_matrix", &projection_matrix);

	gpu.uniform_vec3(program, "position", position);
	gpu.uniform_vec3(program, "scale", scale);

	gpu.uniform_float(program, "time", time);

	if depth_test {
		gpu.enable(.Depth_Test);
	}
	else {
		gpu.disable(.Depth_Test);
	}
	gpu.log_errors(#procedure);

	for mesh, i in model.meshes {
		gpu.bind_vao(mesh.vao);
		gpu.bind_vbo(mesh.vbo);
		gpu.bind_ibo(mesh.ibo);

		// todo(josh): handle multiple textures per model
		#partial
		switch texture.target {
			case .Texture2D: gpu.bind_texture_2d(texture.gpu_id);
			case .Texture3D: gpu.bind_texture_3d(texture.gpu_id);
			case cast(gpu.Texture_Target)0:
			case: panic(tprint(texture.target));
		}

		gpu.log_errors(#procedure);

		if len(anim_state.mesh_states) > i {

			mesh_state := anim_state.mesh_states[i];
			for _, i in mesh_state.state {
				s := mesh_state.state[i];
				bone := strings.unsafe_string_to_cstring(tprint("bones[", i, "]\x00"));
				gpu.uniform_matrix4fv(program, bone, 1, false, &s[0][0]);
			}
		}

		// todo(josh): I don't think we need this since VAOs store the VertexAttribPointer calls
		gpu.set_vertex_format(mesh.vertex_type);
		gpu.log_errors(#procedure);

		if mesh.index_count > 0 {
			gpu.draw_elephants(current_camera.draw_mode, mesh.index_count, .Unsigned_Int, nil);
		}
		else {
			gpu.draw_arrays(current_camera.draw_mode, 0, mesh.vertex_count);
		}
	}
}



//
// Rendermodes
//

// todo(josh): maybe do a push/pop rendermode kinda thing?
// todo(josh): we should _definitely_ do a push/pop rendermode kinda thing. have had bugs related to this a few times now

Rendermode :: enum {
    World,
    Unit,
    Pixel,
}

@(deferred_out=pop_rendermode)
PUSH_RENDERMODE :: proc(r: Rendermode) -> Rendermode {
	old := current_camera.current_rendermode;
	current_camera.current_rendermode = r;
	return old;
}
pop_rendermode :: proc(r: Rendermode) {
	current_camera.current_rendermode = r;
}




//
// Helpers
//

get_mouse_world_position :: proc(camera: ^Camera, cursor_unit_position: Vec2) -> Vec3 {
	cursor_viewport_position := to_vec4((cursor_unit_position * 2) - Vec2{1, 1});
	cursor_viewport_position.w = 1;

	cursor_viewport_position.z = 0.1; // just some way down the frustum, will behave differently for opengl and directx

	inv := mat4_inverse(mul(construct_projection_matrix(camera), construct_view_matrix(camera)));

	cursor_world_position4 := mul(inv, cursor_viewport_position);
	if cursor_world_position4.w != 0 do cursor_world_position4 /= cursor_world_position4.w;
	cursor_world_position := to_vec3(cursor_world_position4);

	return cursor_world_position;
}

get_mouse_direction_from_camera :: proc(camera: ^Camera, cursor_unit_position: Vec2) -> Vec3 {
	if !camera.is_perspective {
		return quaternion_forward(camera.rotation);
	}

	cursor_world_position := get_mouse_world_position(camera, cursor_unit_position);
	cursor_direction := norm(cursor_world_position - camera.position);
	return cursor_direction;
}

world_to_viewport :: proc(position: Vec3, camera: ^Camera) -> Vec3 {
	proj := construct_projection_matrix(camera);
	mv := mul(proj, construct_view_matrix(camera));
	result := mul(mv, Vec4{position.x, position.y, position.z, 1});
	if result.w > 0 do result /= result.w;
	return Vec3{result.x, result.y, result.z};
}
world_to_pixel :: proc(a: Vec3, camera: ^Camera, pixel_width: f32, pixel_height: f32) -> Vec3 {
	result := world_to_viewport(a, camera);
	result = viewport_to_pixel(result, pixel_width, pixel_height);
	return result;
}
world_to_unit :: proc(a: Vec3, camera: ^Camera) -> Vec3 {
	result := world_to_viewport(a, camera);
	result = viewport_to_unit(result);
	return result;
}

unit_to_pixel :: proc(a: Vec3, pixel_width: f32, pixel_height: f32) -> Vec3 {
	result := a * Vec3{pixel_width, pixel_height, 1};
	return result;
}
unit_to_viewport :: proc(a: Vec3) -> Vec3 {
	result := (a * 2) - Vec3{1, 1, 0};
	return result;
}

pixel_to_viewport :: proc(a: Vec3, pixel_width: f32, pixel_height: f32) -> Vec3 {
	a := a;
	a /= Vec3{pixel_width/2, pixel_height/2, 1};
	a -= Vec3{1, 1, 0};
	return a;
}
pixel_to_unit :: proc(a: Vec3, pixel_width: f32, pixel_height: f32) -> Vec3 {
	a := a;
	a /= Vec3{pixel_width, pixel_height, 1};
	return a;
}

viewport_to_pixel :: proc(a: Vec3, pixel_width: f32, pixel_height: f32) -> Vec3 {
	a := a;
	a += Vec3{1, 1, 0};
	a *= Vec3{pixel_width/2, pixel_height/2, 0};
	a.z = 0;
	return a;
}
viewport_to_unit :: proc(a: Vec3) -> Vec3 {
	a := a;
	a += Vec3{1, 1, 0};
	a /= 2;
	a.z = 0;
	return a;
}
viewport_to_world :: proc(camera: ^Camera, viewport_position: Vec3) -> Vec3 {
	viewport_position4 := to_vec4(viewport_position);

	inv := mat4_inverse(mul(construct_projection_matrix(camera), construct_view_matrix(camera)));

	viewport_position4 = mul(inv, viewport_position4);
	if viewport_position4.w != 0 do viewport_position4 /= viewport_position4.w;
	world_position := to_vec3(viewport_position4);

	return world_position;
}