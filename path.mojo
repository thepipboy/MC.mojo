# Add these near the top with other imports
from pathlib import Path
import os
import struct

# ========================
# Constants for Saving/Loading
# ========================

alias WORLD_DIR = "worlds"
alias CHUNK_FILE_EXT = ".chunk"
alias CHUNK_DATA_VERSION = 1

# ========================
# Chunk File Format
# ========================
# Header (16 bytes):
#   - Magic number: 4 bytes ('MCHK')
#   - Version: 2 bytes (unsigned short)
#   - Timestamp: 8 bytes (long long)
#   - Reserved: 2 bytes
# Data:
#   - Block data: CHUNK_SIZE^3 bytes

# ========================
# World Directory Management
# ========================

fn ensure_world_dir_exists(world_name: String) -> String:
    let world_path = Path(WORLD_DIR) / world_name
    if not os.path.exists(world_path):
        os.makedirs(world_path)
    return world_path

fn get_chunk_filename(world_name: String, pos: ChunkPosition) -> String:
    return f"{world_name}/c.{pos.x}.{pos.y}.{pos.z}{CHUNK_FILE_EXT}"

# ========================
# Chunk Serialization
# ========================

fn Chunk.save_to_file(self, world_name: String) -> Bool:
    let world_path = ensure_world_dir_exists(world_name)
    let filename = get_chunk_filename(world_name, self.position)
    let filepath = Path(world_path) / filename
    
    try:
        with open(filepath, "wb") as f:
            # Write header
            f.write(b'MCHK')  # Magic number
            f.write(struct.pack('H', CHUNK_DATA_VERSION))  # Version
            f.write(struct.pack('Q', int(time.time())))  # Timestamp
            f.write(b'\x00\x00')  # Reserved
            
            # Write block data
            for i in range(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE):
                f.write(struct.pack('B', self.blocks.load(i)))
        return True
    except:
        return False

fn Chunk.load_from_file(self, world_name: String) -> Bool:
    let world_path = ensure_world_dir_exists(world_name)
    let filename = get_chunk_filename(world_name, self.position)
    let filepath = Path(world_path) / filename
    
    if not os.path.exists(filepath):
        return False
    
    try:
        with open(filepath, "rb") as f:
            # Read and verify header
            magic = f.read(4)
            if magic != b'MCHK':
                return False
                
            version = struct.unpack('H', f.read(2))[0]
            if version > CHUNK_DATA_VERSION:
                return False
                
            _ = f.read(10)  # Skip timestamp and reserved
            
            # Read block data
            for i in range(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE):
                self.blocks.store(i, struct.unpack('B', f.read(1))[0])
            
            self.modified = False
            return True
    except:
        return False

# ========================
# Updated World Class
# ========================

class World:
    var world_name: String
    # ... (previous fields)
    
    fn __init__(world_name: String = "default", render_distance: Int = RENDER_DISTANCE):
        self.world_name = world_name
        self.chunks = Dict[ChunkPosition, Chunk]()
        self.render_distance = render_distance
        ensure_world_dir_exists(world_name)
    
    fn get_chunk(self, position: ChunkPosition) -> Chunk:
        if position not in self.chunks:
            let chunk = Chunk(position)
            
            # Try to load from file first
            if not chunk.load_from_file(self.world_name):
                # If not found, generate new terrain
                chunk.generate_terrain()
                chunk.save_to_file(self.world_name)  # Save newly generated chunk
            
            self.chunks[position] = chunk
        return self.chunks[position]
    
    fn save_all_chunks(self):
        var saved = 0
        for pos, chunk in self.chunks.items():
            if chunk.modified:
                if chunk.save_to_file(self.world_name):
                    chunk.modified = False
                    saved += 1
        return saved

# ========================
# Updated Main Game Loop
# ========================

fn main():
    # ... (previous initialization code)
    
    # Create world with name
    let world_name = "my_world"
    let world = World(world_name)
    
    try:
        while running:
            # ... (game loop code)
            
            # Periodically save chunks (every 60 seconds)
            if int(time.time()) % 60 == 0:
                let saved = world.save_all_chunks()
                if saved > 0:
                    print(f"Auto-saved {saved} chunks")
    
    finally:
        # Save all modified chunks on exit
        let saved = world.save_all_chunks()
        print(f"Saved {saved} chunks on exit")
        pygame.quit()