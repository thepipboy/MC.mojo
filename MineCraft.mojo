# main.mojo - Minecraft Clone
from python import Python
import pygame
from pygame.locals import *
from OpenGL.GL import *
from OpenGL.GLU import *
from math import sin, cos, radians, floor
import random
import time
import numpy as np

# ========================
# Constants and Types
# ========================

alias CHUNK_SIZE = 16
alias WORLD_HEIGHT = 256
alias RENDER_DISTANCE = 4
alias BLOCK_SIZE = 1.0

struct Vector3:
    var x: Float32
    var y: Float32
    var z: Float32

    fn __init__(x: Float32, y: Float32, z: Float32) -> Self:
        return Self {x: x, y: y, z: z}
    
    fn __add__(self, other: Self) -> Self:
        return Vector3(self.x + other.x, self.y + other.y, self.z + other.z)
    
    fn __sub__(self, other: Self) -> Self:
        return Vector3(self.x - other.x, self.y - other.y, self.z - other.z)

struct BlockPosition:
    var x: Int
    var y: Int
    var z: Int
    
    fn __init__(x: Int, y: Int, z: Int) -> Self:
        return Self {x: x, y: y, z: z}
    
    fn to_vector3(self) -> Vector3:
        return Vector3(self.x * BLOCK_SIZE, self.y * BLOCK_SIZE, self.z * BLOCK_SIZE)

struct ChunkPosition:
    var x: Int
    var z: Int
    
    fn __init__(x: Int, z: Int) -> Self:
        return Self {x: x, z: z}
    
    fn to_world_position(self) -> Vector3:
        return Vector3(self.x * CHUNK_SIZE * BLOCK_SIZE, 0, self.z * CHUNK_SIZE * BLOCK_SIZE)

enum BlockType:
    AIR
    GRASS
    DIRT
    STONE
    BEDROCK
    WATER
    WOOD
    LEAVES

# ========================
# Block Data
# ========================

struct BlockData:
    var type: BlockType
    var is_transparent: Bool
    
    fn __init__(type: BlockType) -> Self:
        var transparent = False
        if type == BlockType.AIR or type == BlockType.WATER or type == BlockType.LEAVES:
            transparent = True
        return Self {type: type, is_transparent: transparent}

# ========================
# Chunk System
# ========================

class Chunk:
    var position: ChunkPosition
    var blocks: DTypePointer[DType.uint8]
    var modified: Bool
    var mesh_built: Bool
    var display_list: Int
    
    fn __init__(self, position: ChunkPosition):
        self.position = position
        self.blocks = DTypePointer[DType.uint8].alloc(CHUNK_SIZE * CHUNK_SIZE * WORLD_HEIGHT)
        self.modified = True
        self.mesh_built = False
        self.display_list = 0
    
    fn __del__(self):
        if self.display_list != 0:
            glDeleteLists(self.display_list, 1)
        self.blocks.free()
    
    fn get_block(self, x: Int, y: Int, z: Int) -> BlockType:
        if x < 0 or x >= CHUNK_SIZE or y < 0 or y >= WORLD_HEIGHT or z < 0 or z >= CHUNK_SIZE:
            return BlockType.AIR
        return BlockType(self.blocks.load(z * CHUNK_SIZE * WORLD_HEIGHT + x * WORLD_HEIGHT + y))
    
    fn set_block(self, x: Int, y: Int, z: Int, block_type: BlockType):
        if x >= 0 and x < CHUNK_SIZE and y >= 0 and y < WORLD_HEIGHT and z >= 0 and z < CHUNK_SIZE:
            self.blocks.store(z * CHUNK_SIZE * WORLD_HEIGHT + x * WORLD_HEIGHT + y, block_type.value)
            self.modified = True
    
    fn generate_terrain(self):
        # Simple terrain generation with noise
        let _ = Python.import_module("noise")
        let noise = Python.import_module("noise").pnoise2
        
        for x in range(CHUNK_SIZE):
            for z in range(CHUNK_SIZE):
                # Calculate world coordinates
                wx = self.position.x * CHUNK_SIZE + x
                wz = self.position.z * CHUNK_SIZE + z
                
                # Generate height using Perlin noise
                height = Int(50 + noise(wx * 0.1, wz * 0.1, octaves=4) * 20)
                
                # Place blocks
                for y in range(WORLD_HEIGHT):
                    if y == 0:
                        self.set_block(x, y, z, BlockType.BEDROCK)
                    elif y < height - 4:
                        self.set_block(x, y, z, BlockType.STONE)
                    elif y < height - 1:
                        self.set_block(x, y, z, BlockType.DIRT)
                    elif y == height - 1:
                        self.set_block(x, y, z, BlockType.GRASS)
                    elif y < 60:  # Water level
                        self.set_block(x, y, z, BlockType.WATER)
                    else:
                        self.set_block(x, y, z, BlockType.AIR)
        
        # Add some trees
        for _ in range(3):
            tx = random.randint(2, CHUNK_SIZE - 3)
            tz = random.randint(2, CHUNK_SIZE - 3)
            
            # Find surface
            ty = 0
            for y in range(WORLD_HEIGHT - 1, 0, -1):
                if self.get_block(tx, y, tz) != BlockType.AIR:
                    ty = y + 1
                    break
            
            if ty > 60:  # Don't place trees underwater
                # Tree trunk
                for y in range(5):
                    self.set_block(tx, ty + y, tz, BlockType.WOOD)
                
                # Tree leaves
                for lx in range(-2, 3):
                    for ly in range(-1, 2):
                        for lz in range(-2, 3):
                            if abs(lx) + abs(lz) + abs(ly) < 4:
                                nx = tx + lx
                                nz = tz + lz
                                ny = ty + 3 + ly
                                if (nx >= 0 and nx < CHUNK_SIZE and 
                                    nz >= 0 and nz < CHUNK_SIZE and 
                                    ny >= 0 and ny < WORLD_HEIGHT):
                                    if self.get_block(nx, ny, nz) == BlockType.AIR:
                                        self.set_block(nx, ny, nz, BlockType.LEAVES)
    
    fn rebuild_mesh(self):
        if self.display_list == 0:
            self.display_list = glGenLists(1)
        
        glNewList(self.display_list, GL_COMPILE)
        glBegin(GL_QUADS)
        
        for x in range(CHUNK_SIZE):
            for y in range(WORLD_HEIGHT):
                for z in range(CHUNK_SIZE):
                    block_type = self.get_block(x, y, z)
                    if block_type != BlockType.AIR:
                        self.draw_block(x, y, z, block_type)
        
        glEnd()
        glEndList()
        self.modified = False
        self.mesh_built = True
    
    fn draw_block(self, x: Int, y: Int, z: Int, block_type: BlockType):
        let block_data = BlockData(block_type)
        let pos = Vector3(x * BLOCK_SIZE, y * BLOCK_SIZE, z * BLOCK_SIZE)
        
        # Get block color based on type
        var color: Vector3
        if block_type == BlockType.GRASS:
            color = Vector3(0.2, 0.8, 0.3)
        elif block_type == BlockType.DIRT:
            color = Vector3(0.5, 0.3, 0.1)
        elif block_type == BlockType.STONE:
            color = Vector3(0.5, 0.5, 0.5)
        elif block_type == BlockType.BEDROCK:
            color = Vector3(0.2, 0.2, 0.2)
        elif block_type == BlockType.WATER:
            color = Vector3(0.2, 0.4, 0.8)
        elif block_type == BlockType.WOOD:
            color = Vector3(0.5, 0.3, 0.1)
        elif block_type == BlockType.LEAVES:
            color = Vector3(0.2, 0.6, 0.2)
        
        # Only draw faces that are adjacent to transparent blocks
        # Front face
        if self.get_block(x, y, z + 1).is_transparent:
            glColor3f(color.x * 0.9, color.y * 0.9, color.z * 0.9)
            glVertex3f(pos.x, pos.y, pos.z + BLOCK_SIZE)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y, pos.z + BLOCK_SIZE)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y + BLOCK_SIZE, pos.z + BLOCK_SIZE)
            glVertex3f(pos.x, pos.y + BLOCK_SIZE, pos.z + BLOCK_SIZE)
        
        # Back face
        if self.get_block(x, y, z - 1).is_transparent:
            glColor3f(color.x * 0.9, color.y * 0.9, color.z * 0.9)
            glVertex3f(pos.x, pos.y, pos.z)
            glVertex3f(pos.x, pos.y + BLOCK_SIZE, pos.z)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y + BLOCK_SIZE, pos.z)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y, pos.z)
        
        # Left face
        if self.get_block(x - 1, y, z).is_transparent:
            glColor3f(color.x * 0.8, color.y * 0.8, color.z * 0.8)
            glVertex3f(pos.x, pos.y, pos.z)
            glVertex3f(pos.x, pos.y, pos.z + BLOCK_SIZE)
            glVertex3f(pos.x, pos.y + BLOCK_SIZE, pos.z + BLOCK_SIZE)
            glVertex3f(pos.x, pos.y + BLOCK_SIZE, pos.z)
        
        # Right face
        if self.get_block(x + 1, y, z).is_transparent:
            glColor3f(color.x * 0.8, color.y * 0.8, color.z * 0.8)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y, pos.z)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y + BLOCK_SIZE, pos.z)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y + BLOCK_SIZE, pos.z + BLOCK_SIZE)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y, pos.z + BLOCK_SIZE)
        
        # Top face
        if self.get_block(x, y + 1, z).is_transparent:
            glColor3f(color.x, color.y, color.z)
            glVertex3f(pos.x, pos.y + BLOCK_SIZE, pos.z)
            glVertex3f(pos.x, pos.y + BLOCK_SIZE, pos.z + BLOCK_SIZE)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y + BLOCK_SIZE, pos.z + BLOCK_SIZE)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y + BLOCK_SIZE, pos.z)
        
        # Bottom face
        if self.get_block(x, y - 1, z).is_transparent:
            glColor3f(color.x * 0.7, color.y * 0.7, color.z * 0.7)
            glVertex3f(pos.x, pos.y, pos.z)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y, pos.z)
            glVertex3f(pos.x + BLOCK_SIZE, pos.y, pos.z + BLOCK_SIZE)
            glVertex3f(pos.x, pos.y, pos.z + BLOCK_SIZE)
    
    fn render(self):
        if not self.mesh_built or self.modified:
            self.rebuild_mesh()
        
        glPushMatrix()
        glTranslatef(
            self.position.x * CHUNK_SIZE * BLOCK_SIZE,
            0,
            self.position.z * CHUNK_SIZE * BLOCK_SIZE
        )
        glCallList(self.display_list)
        glPopMatrix()

# ========================
# World Management
# ========================

class World:
    var chunks: Dict[ChunkPosition, Chunk]
    var render_distance: Int
    
    fn __init__(render_distance: Int = RENDER_DISTANCE):
        self.chunks = Dict[ChunkPosition, Chunk]()
        self.render_distance = render_distance
    
    fn get_chunk(self, position: ChunkPosition) -> Chunk:
        if position not in self.chunks:
            let chunk = Chunk(position)
            chunk.generate_terrain()
            self.chunks[position] = chunk
        return self.chunks[position]
    
    fn get_block(self, world_x: Int, world_y: Int, world_z: Int) -> BlockType:
        let chunk_x = world_x // CHUNK_SIZE
        let chunk_z = world_z // CHUNK_SIZE
        let local_x = world_x % CHUNK_SIZE
        let local_z = world_z % CHUNK_SIZE
        
        if world_y < 0 or world_y >= WORLD_HEIGHT:
            return BlockType.AIR
        
        if (chunk_x, chunk_z) in self.chunks:
            return self.chunks[(chunk_x, chunk_z)].get_block(local_x, world_y, local_z)
        return BlockType.AIR
    
    fn set_block(self, world_x: Int, world_y: Int, world_z: Int, block_type: BlockType):
        let chunk_x = world_x // CHUNK_SIZE
        let chunk_z = world_z // CHUNK_SIZE
        let local_x = world_x % CHUNK_SIZE
        let local_z = world_z % CHUNK_SIZE
        
        if world_y >= 0 and world_y < WORLD_HEIGHT:
            let chunk = self.get_chunk(ChunkPosition(chunk_x, chunk_z))
            chunk.set_block(local_x, world_y, local_z, block_type)
    
    fn update_chunks(self, center: ChunkPosition):
        # Unload distant chunks
        for pos in list(self.chunks.keys()):
            if abs(pos.x - center.x) > self.render_distance or abs(pos.z - center.z) > self.render_distance:
                del self.chunks[pos]
        
        # Load new chunks
        for x in range(center.x - self.render_distance, center.x + self.render_distance + 1):
            for z in range(center.z - self.render_distance, center.z + self.render_distance + 1):
                if (x, z) not in self.chunks:
                    self.get_chunk(ChunkPosition(x, z))
    
    fn render(self):
        for chunk in self.chunks.values():
            chunk.render()

# ========================
# Player System
# ========================

class Player:
    var position: Vector3
    var rotation: Vector3
    var velocity: Vector3
    var on_ground: Bool
    var height: Float32
    var width: Float32
    var eye_height: Float32
    var move_speed: Float32
    var jump_force: Float32
    var gravity: Float32
    
    fn __init__():
        self.position = Vector3(0, 70, 0)
        self.rotation = Vector3(0, 0, 0)
        self.velocity = Vector3(0, 0, 0)
        self.on_ground = False
        self.height = 1.8
        self.width = 0.6
        self.eye_height = 1.6
        self.move_speed = 5.0
        self.jump_force = 7.0
        self.gravity = 20.0
    
    fn update(self, dt: Float32, world: World):
        # Apply gravity
        self.velocity.y -= self.gravity * dt
        
        # Move player
        let move_dir = self.get_move_direction()
        let move_speed = self.move_speed * dt
        self.velocity.x = move_dir.x * move_speed
        self.velocity.z = move_dir.z * move_speed
        
        # Apply velocity
        let new_position = self.position + self.velocity
        
        # Collision detection
        self.handle_collision(new_position, world)
        
        # Reset vertical velocity if on ground
        if self.on_ground:
            self.velocity.y = max(0.0, self.velocity.y)
    
    fn get_move_direction(self) -> Vector3:
        let sin_yaw = sin(radians(self.rotation.y))
        let cos_yaw = cos(radians(self.rotation.y))
        
        var move_dir = Vector3(0, 0, 0)
        let keys = pygame.key.get_pressed()
        
        if keys[K_w]:
            move_dir.z -= 1
        if keys[K_s]:
            move_dir.z += 1
        if keys[K_a]:
            move_dir.x -= 1
        if keys[K_d]:
            move_dir.x += 1
        
        # Normalize and rotate by yaw
        if move_dir.x != 0 or move_dir.z != 0:
            let length = (move_dir.x**2 + move_dir.z**2)**0.5
            move_dir.x /= length
            move_dir.z /= length
            
            # Rotate by yaw
            let x = move_dir.x * cos_yaw - move_dir.z * sin_yaw
            let z = move_dir.x * sin_yaw + move_dir.z * cos_yaw
            move_dir.x = x
            move_dir.z = z
        
        return move_dir
    
    fn handle_collision(self, new_position: Vector3, world: World):
        # Check collision with blocks
        let min_x = floor(new_position.x - self.width / 2)
        let max_x = floor(new_position.x + self.width / 2)
        let min_y = floor(new_position.y)
        let max_y = floor(new_position.y + self.height)
        let min_z = floor(new_position.z - self.width / 2)
        let max_z = floor(new_position.z + self.width / 2)
        
        var collision = False
        self.on_ground = False
        
        # Check all blocks in player's bounding box
        for x in range(min_x, max_x + 1):
            for y in range(min_y, max_y + 1):
                for z in range(min_z, max_z + 1):
                    if world.get_block(x, y, z) != BlockType.AIR:
                        # Collision detected
                        collision = True
                        
                        # Check if block is below player
                        if y < self.position.y + self.height / 2 and self.velocity.y < 0:
                            self.on_ground = True
                            self.velocity.y = 0
                            new_position.y = y + 1
                        
                        # Check if block is above player
                        elif y > self.position.y + self.height / 2 and self.velocity.y > 0:
                            self.velocity.y = 0
                            new_position.y = y - self.height
                        
                        # X-axis collision
                        elif x < self.position.x:
                            new_position.x = x + 1 + self.width / 2
                            self.velocity.x = 0
                        elif x > self.position.x:
                            new_position.x = x - self.width / 2
                            self.velocity.x = 0
                        
                        # Z-axis collision
                        elif z < self.position.z:
                            new_position.z = z + 1 + self.width / 2
                            self.velocity.z = 0
                        elif z > self.position.z:
                            new_position.z = z - self.width / 2
                            self.velocity.z = 0
        
        if not collision:
            self.position = new_position
        else:
            self.position.x = new_position.x
            self.position.z = new_position.z
            if not self.on_ground:
                self.position.y = new_position.y
    
    fn jump(self):
        if self.on_ground:
            self.velocity.y = self.jump_force
            self.on_ground = False
    
    fn get_eye_position(self) -> Vector3:
        return Vector3(
            self.position.x,
            self.position.y + self.eye_height,
            self.position.z
        )

# ========================
# Input System
# ========================

class InputHandler:
    var mouse_sensitivity: Float32
    var mouse_captured: Bool
    var last_mouse_pos: (Int, Int)
    
    fn __init__():
        self.mouse_sensitivity = 0.1
        self.mouse_captured = False
        self.last_mouse_pos = (0, 0)
    
    fn handle_events(self, player: Player, world: World):
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                return False
            
            # Mouse capture/release
            elif event.type == pygame.KEYDOWN:
                if event.key == K_ESCAPE:
                    self.mouse_captured = not self.mouse_captured
                    pygame.mouse.set_visible(not self.mouse_captured)
                    pygame.event.set_grab(self.mouse_captured)
                    if self.mouse_captured:
                        pygame.mouse.set_pos(pygame.display.get_surface().get_size()[0] // 2, 
                                           pygame.display.get_surface().get_size()[1] // 2)
                
                # Block placement/destruction
                elif event.key == K_1:
                    self.place_or_remove_block(player, world, BlockType.GRASS, place=True)
                elif event.key == K_2:
                    self.place_or_remove_block(player, world, BlockType.DIRT, place=True)
                elif event.key == K_3:
                    self.place_or_remove_block(player, world, BlockType.STONE, place=True)
                elif event.key == K_4:
                    self.place_or_remove_block(player, world, BlockType.WOOD, place=True)
                elif event.key == K_5:
                    self.place_or_remove_block(player, world, BlockType.LEAVES, place=True)
                elif event.key == K_SPACE:
                    player.jump()
            
            # Mouse look
            elif event.type == pygame.MOUSEMOTION and self.mouse_captured:
                dx, dy = event.rel
                player.rotation.y += dx * self.mouse_sensitivity
                player.rotation.x -= dy * self.mouse_sensitivity
                player.rotation.x = max(-89.9, min(89.9, player.rotation.x))
        
        return True
    
    fn place_or_remove_block(self, player: Player, world: World, block_type: BlockType, place: Bool):
        let eye_pos = player.get_eye_position()
        let direction = self.get_look_direction(player)
        
        # Raycast to find target block
        var reach = 0
        while reach < 6:  # 6 block reach
            let check_pos = Vector3(
                eye_pos.x + direction.x * reach,
                eye_pos.y + direction.y * reach,
                eye_pos.z + direction.z * reach
            )
            
            let block_x = floor(check_pos.x)
            let block_y = floor(check_pos.y)
            let block_z = floor(check_pos.z)
            
            let block = world.get_block(block_x, block_y, block_z)
            if block != BlockType.AIR:
                if place:
                    # Place block on adjacent face
                    let place_pos = Vector3(
                        eye_pos.x + direction.x * (reach - 0.5),
                        eye_pos.y + direction.y * (reach - 0.5),
                        eye_pos.z + direction.z * (reach - 0.5)
                    )
                    world.set_block(floor(place_pos.x), floor(place_pos.y), floor(place_pos.z), block_type)
                else:
                    # Remove block
                    world.set_block(block_x, block_y, block_z, BlockType.AIR)
                break
            
            reach += 0.1
    
    fn get_look_direction(self, player: Player) -> Vector3:
        let yaw = radians(player.rotation.y)
        let pitch = radians(player.rotation.x)
        
        return Vector3(
            cos(pitch) * sin(yaw),
            sin(pitch),
            cos(pitch) * cos(yaw)
        )

# ========================
# Rendering System
# ========================

class Renderer:
    var fov: Float32
    var near_plane: Float32
    var far_plane: Float32
    
    fn __init__():
        self.fov = 70.0
        self.near_plane = 0.1
        self.far_plane = 500.0
    
    fn setup(self, width: Int, height: Int):
        glViewport(0, 0, width, height)
        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        gluPerspective(self.fov, width / height, self.near_plane, self.far_plane)
        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()
        
        glEnable(GL_DEPTH_TEST)
        glEnable(GL_CULL_FACE)
        glCullFace(GL_BACK)
        
        # Basic lighting
        glEnable(GL_LIGHTING)
        glEnable(GL_LIGHT0)
        glLightfv(GL_LIGHT0, GL_POSITION, (0.5, 1.0, 0.5, 0.0))
        glLightfv(GL_LIGHT0, GL_AMBIENT, (0.2, 0.2, 0.2, 1.0))
        glLightfv(GL_LIGHT0, GL_DIFFUSE, (0.8, 0.8, 0.8, 1.0))
        
        glClearColor(0.6, 0.8, 1.0, 1.0)  # Sky color
    
    fn begin_frame(self):
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
        glLoadIdentity()
    
    def render_player_view(self, player: Player):
        let eye_pos = player.get_eye_position()
        let look_dir = Vector3(
            sin(radians(player.rotation.y)) * cos(radians(player.rotation.x)),
            sin(radians(player.rotation.x)),
            cos(radians(player.rotation.y)) * cos(radians(player.rotation.x))
        )
        
        let center = eye_pos + look_dir
        gluLookAt(
            eye_pos.x, eye_pos.y, eye_pos.z,
            center.x, center.y, center.z,
            0, 1, 0
        )
        
        # Update light position to follow player
        glLightfv(GL_LIGHT0, GL_POSITION, (eye_pos.x, eye_pos.y + 10, eye_pos.z, 1.0))

# ========================
# Main Game Loop
# ========================

fn main():
    # Initialize pygame and OpenGL
    let _ = Python.add_to_path("")
    pygame.init()
    
    display = (1280, 720)
    pygame.display.set_mode(display, DOUBLEBUF | OPENGL)
    pygame.display.set_caption("MojoCraft")
    
    # Initialize systems
    let renderer = Renderer()
    renderer.setup(display[0], display[1])
    
    let world = World()
    let player = Player()
    let input_handler = InputHandler()
    
    # Capture mouse initially
    input_handler.mouse_captured = True
    pygame.mouse.set_visible(False)
    pygame.event.set_grab(True)
    pygame.mouse.set_pos(display[0] // 2, display[1] // 2)
    
    # Main game loop
    var running = True
    var last_time = time.time()
    
    while running:
        # Calculate delta time
        let current_time = time.time()
        let dt = min(0.1, current_time - last_time)  # Cap at 100ms
        last_time = current_time
        
        # Handle input
        running = input_handler.handle_events(player, world)
        
        # Update player
        player.update(dt, world)
        
        # Update chunks around player
        let chunk_x = floor(player.position.x / CHUNK_SIZE)
        let chunk_z = floor(player.position.z / CHUNK_SIZE)
        world.update_chunks(ChunkPosition(chunk_x, chunk_z))
        
        # Rendering
        renderer.begin_frame()
        renderer.render_player_view(player)
        world.render()
        
        # Draw crosshair
        glDisable(GL_DEPTH_TEST)
        glDisable(GL_LIGHTING)
        glMatrixMode(GL_PROJECTION)
        glPushMatrix()
        glLoadIdentity()
        gluOrtho2D(0, display[0], display[1], 0)
        glMatrixMode(GL_MODELVIEW)
        glPushMatrix()
        glLoadIdentity()
        
        glColor3f(1, 1, 1)
        glBegin(GL_LINES)
        glVertex2f(display[0] // 2 - 10, display[1] // 2)
        glVertex2f(display[0] // 2 + 10, display[1] // 2)
        glVertex2f(display[0] // 2, display[1] // 2 - 10)
        glVertex2f(display[0] // 2, display[1] // 2 + 10)
        glEnd()
        
        glMatrixMode(GL_PROJECTION)
        glPopMatrix()
        glMatrixMode(GL_MODELVIEW)
        glPopMatrix()
        glEnable(GL_DEPTH_TEST)
        glEnable(GL_LIGHTING)
        
        pygame.display.flip()
        pygame.time.wait(10)
    
    pygame.quit()

if __name__ == "__main__":
    main()