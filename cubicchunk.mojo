# main.mojo - Updated for 16x16x16 isotropic chunks

# ========================
# Updated Constants
# ========================

alias CHUNK_SIZE = 16
alias WORLD_HEIGHT_CHUNKS = 16  # Number of chunks vertically
alias RENDER_DISTANCE = 4
alias BLOCK_SIZE = 1.0
alias WORLD_HEIGHT = CHUNK_SIZE * WORLD_HEIGHT_CHUNKS  # Total world height in blocks

# ========================
# Updated Chunk System
# ========================

class Chunk:
    var position: ChunkPosition
    var blocks: DTypePointer[DType.uint8]
    var modified: Bool
    var mesh_built: Bool
    var display_list: Int
    
    fn __init__(self, position: ChunkPosition):
        self.position = position
        # Now using CHUNK_SIZE^3 for isotropic chunks
        self.blocks = DTypePointer[DType.uint8].alloc(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)
        self.modified = True
        self.mesh_built = False
        self.display_list = 0
    
    fn __del__(self):
        if self.display_list != 0:
            glDeleteLists(self.display_list, 1)
        self.blocks.free()
    
    fn get_block(self, x: Int, y: Int, z: Int) -> BlockType:
        # Convert world Y to chunk-local Y
        let chunk_y = y // CHUNK_SIZE
        let local_y = y % CHUNK_SIZE
        
        # Only return blocks if within this chunk's vertical range
        if (x < 0 or x >= CHUNK_SIZE or 
            chunk_y != self.position.y or 
            z < 0 or z >= CHUNK_SIZE or 
            local_y < 0 or local_y >= CHUNK_SIZE):
            return BlockType.AIR
        
        return BlockType(self.blocks.load(
            z * CHUNK_SIZE * CHUNK_SIZE + 
            x * CHUNK_SIZE + 
            local_y
        ))
    
    fn set_block(self, x: Int, y: Int, z: Int, block_type: BlockType):
        let chunk_y = y // CHUNK_SIZE
        let local_y = y % CHUNK_SIZE
        
        if (x >= 0 and x < CHUNK_SIZE and 
            chunk_y == self.position.y and 
            z >= 0 and z < CHUNK_SIZE and 
            local_y >= 0 and local_y < CHUNK_SIZE):
            
            self.blocks.store(
                z * CHUNK_SIZE * CHUNK_SIZE + 
                x * CHUNK_SIZE + 
                local_y,
                block_type.value
            )
            self.modified = True

# ========================
# Updated World Management
# ========================

struct ChunkPosition:
    var x: Int
    var y: Int  # Now tracking vertical chunk position
    var z: Int
    
    fn __init__(x: Int, y: Int, z: Int) -> Self:
        return Self {x: x, y: y, z: z}
    
    fn to_world_position(self) -> Vector3:
        return Vector3(
            self.x * CHUNK_SIZE * BLOCK_SIZE,
            self.y * CHUNK_SIZE * BLOCK_SIZE,
            self.z * CHUNK_SIZE * BLOCK_SIZE
        )

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
        let chunk_y = world_y // CHUNK_SIZE
        let chunk_z = world_z // CHUNK_SIZE
        
        let local_x = world_x % CHUNK_SIZE
        let local_y = world_y % CHUNK_SIZE
        let local_z = world_z % CHUNK_SIZE
        
        if (world_y < 0 or world_y >= WORLD_HEIGHT or
            chunk_y < 0 or chunk_y >= WORLD_HEIGHT_CHUNKS):
            return BlockType.AIR
        
        if (chunk_x, chunk_y, chunk_z) in self.chunks:
            return self.chunks[(chunk_x, chunk_y, chunk_z)].get_block(local_x, world_y, local_z)
        return BlockType.AIR
    
    fn set_block(self, world_x: Int, world_y: Int, world_z: Int, block_type: BlockType):
        let chunk_x = world_x // CHUNK_SIZE
        let chunk_y = world_y // CHUNK_SIZE
        let chunk_z = world_z // CHUNK_SIZE
        
        let local_x = world_x % CHUNK_SIZE
        let local_y = world_y % CHUNK_SIZE
        let local_z = world_z % CHUNK_SIZE
        
        if (world_y >= 0 and world_y < WORLD_HEIGHT and
            chunk_y >= 0 and chunk_y < WORLD_HEIGHT_CHUNKS):
            
            let chunk = self.get_chunk(ChunkPosition(chunk_x, chunk_y, chunk_z))
            chunk.set_block(local_x, world_y, local_z, block_type)
    
    fn update_chunks(self, player_pos: Vector3):
        # Convert player position to chunk coordinates
        let center_x = floor(player_pos.x / CHUNK_SIZE)
        let center_y = floor(player_pos.y / CHUNK_SIZE)
        let center_z = floor(player_pos.z / CHUNK_SIZE)
        
        # Unload distant chunks
        for pos in list(self.chunks.keys()):
            if (abs(pos.x - center_x) > self.render_distance or
                abs(pos.y - center_y) > self.render_distance or
                abs(pos.z - center_z) > self.render_distance):
                del self.chunks[pos]
        
        # Load new chunks
        for x in range(center_x - self.render_distance, center_x + self.render_distance + 1):
            for y in range(max(0, center_y - self.render_distance), 
                         min(WORLD_HEIGHT_CHUNKS, center_y + self.render_distance + 1)):
                for z in range(center_z - self.render_distance, center_z + self.render_distance + 1):
                    if (x, y, z) not in self.chunks:
                        self.get_chunk(ChunkPosition(x, y, z))
    
    fn render(self):
        for chunk in self.chunks.values():
            chunk.render()

# ========================
# Updated Chunk Generation
# ========================

fn Chunk.generate_terrain(self):
    # Simple terrain generation with noise
    let _ = Python.import_module("noise")
    let noise = Python.import_module("noise").pnoise2
    
    for x in range(CHUNK_SIZE):
        for z in range(CHUNK_SIZE):
            # Calculate world coordinates
            wx = self.position.x * CHUNK_SIZE + x
            wz = self.position.z * CHUNK_SIZE + z
            wy_base = self.position.y * CHUNK_SIZE
            
            # Generate base height using Perlin noise
            height = Int(50 + noise(wx * 0.1, wz * 0.1, octaves=4) * 20)
            
            # Place blocks in this chunk's vertical range
            for local_y in range(CHUNK_SIZE):
                world_y = wy_base + local_y
                
                if world_y == 0:
                    self.set_block(x, world_y, z, BlockType.BEDROCK)
                elif world_y < height - 4:
                    self.set_block(x, world_y, z, BlockType.STONE)
                elif world_y < height - 1:
                    self.set_block(x, world_y, z, BlockType.DIRT)
                elif world_y == height - 1:
                    self.set_block(x, world_y, z, BlockType.GRASS)
                elif world_y < 60:  # Water level
                    self.set_block(x, world_y, z, BlockType.WATER)
                else:
                    self.set_block(x, world_y, z, BlockType.AIR)
    
    # Add some trees (only if this is a surface chunk)
    if self.position.y == (60 // CHUNK_SIZE):
        for _ in range(3):
            tx = random.randint(2, CHUNK_SIZE - 3)
            tz = random.randint(2, CHUNK_SIZE - 3)
            
            # Find surface in this chunk
            for local_y in range(CHUNK_SIZE - 1, -1, -1):
                world_y = self.position.y * CHUNK_SIZE + local_y
                if self.get_block(tx, world_y, tz) == BlockType.GRASS:
                    # Tree trunk (spans multiple chunks)
                    for ty in range(5):
                        world.set_block(
                            wx + tx, 
                            world_y + 1 + ty, 
                            wz + tz, 
                            BlockType.WOOD
                        )
                    
                    # Tree leaves (may span multiple chunks)
                    for lx in range(-2, 3):
                        for ly in range(-1, 2):
                            for lz in range(-2, 3):
                                if abs(lx) + abs(lz) + abs(ly) < 4:
                                    world.set_block(
                                        wx + tx + lx,
                                        world_y + 4 + ly,
                                        wz + tz + lz,
                                        BlockType.LEAVES
                                    )
                    break

# ========================
# Updated Player Physics
# ========================

class Player:
    # ... (previous code remains the same until handle_collision)
    
    fn handle_collision(self, new_position: Vector3, world: World):
        # Check collision with blocks
        let min_x = floor(new_position.x - self.width / 2)
        let max_x = floor(new_position.x + self.width / 2)
        let min_y = floor(new_position.y - self.width / 2)
        let max_y = floor(new_position.y + self.width / 2)
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

# ========================
# Updated Main Game Loop
# ========================

fn main():
    # ... (initialization code remains the same)
    
    while running:
        # Calculate delta time
        let current_time = time.time()
        let dt = min(0.1, current_time - last_time)
        last_time = current_time
        
        # Handle input
        running = input_handler.handle_events(player, world)
        
        # Update player
        player.update(dt, world)
        
        # Update chunks around player (now using 3D chunk coordinates)
        world.update_chunks(player.position)
        
        # Rendering
        renderer.begin_frame()
        renderer.render_player_view(player)
        world.render()
        
        # ... (rest of the rendering code remains the same)
    
    pygame.quit()
