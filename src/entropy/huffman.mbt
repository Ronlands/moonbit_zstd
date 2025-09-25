/// Huffman decoder implementation
/// Used for decoding literals in ZSTD

import core::types::{HuffmanTableEntry}
import core::bitstream::{BitStream, read_bit}

/// Huffman decoder state
pub struct HuffmanDecoder {
  table : Array[HuffmanTableEntry]
  root : Int
}

/// Create Huffman decoder from table
pub fn new_huffman_decoder(table : Array[HuffmanTableEntry]) -> HuffmanDecoder {
  HuffmanDecoder {
    table: table
    root: 0
  }
}

/// Decode next symbol from Huffman stream
pub fn decode_symbol(decoder : HuffmanDecoder, stream : BitStream) -> (HuffmanDecoder, BitStream, Int) {
  let mut current_node = decoder.root
  let mut current_stream = stream
  
  // Traverse Huffman tree
  while current_node < decoder.table.length() {
    let (new_stream, bit) = read_bit(current_stream)
    current_stream = new_stream
    
    let entry = decoder.table[current_node]
    if bit == 0 {
      // Go left
      current_node = current_node * 2 + 1
    } else {
      // Go right  
      current_node = current_node * 2 + 2
    }
    
    // Check if we found a leaf
    if current_node >= decoder.table.length() {
      break
    }
    
    let next_entry = decoder.table[current_node]
    if next_entry.symbol >= 0 {
      // Found a symbol
      return (decoder, current_stream, next_entry.symbol)
    }
  }
  
  // Fallback - return first symbol
  (decoder, current_stream, 0)
}

/// Build Huffman table from frequency distribution
pub fn build_huffman_table(frequencies : Array[Int]) -> Array[HuffmanTableEntry] {
  // Create nodes for each symbol
  let mut nodes = Array::new()
  for i = 0; i < frequencies.length(); i = i + 1 {
    if frequencies[i] > 0 {
      nodes = nodes.append(HuffmanNode {
        symbol: i
        frequency: frequencies[i]
        left: -1
        right: -1
        parent: -1
      })
    }
  }
  
  if nodes.length() == 0 {
    // No symbols
    return Array::new()
  }
  
  if nodes.length() == 1 {
    // Single symbol - create simple table
    let mut table = Array::new()
    table = table.append(HuffmanTableEntry {
      symbol: nodes[0].symbol
      code: 0
      bits: 1
    })
    return table
  }
  
  // Build Huffman tree
  let mut heap = nodes
  while heap.length() > 1 {
    // Sort by frequency
    heap = sort_by_frequency(heap)
    
    // Take two lowest frequency nodes
    let left = heap[0]
    let right = heap[1]
    
    // Create parent node
    let parent = HuffmanNode {
      symbol: -1
      frequency: left.frequency + right.frequency
      left: 0
      right: 1
      parent: -1
    }
    
    // Update heap
    let mut new_heap = Array::new()
    new_heap = new_heap.append(parent)
    for i = 2; i < heap.length(); i = i + 1 {
      new_heap = new_heap.append(heap[i])
    }
    heap = new_heap
  }
  
  // Generate codes from tree
  let root = heap[0]
  generate_codes(root, 0, 0, heap)
}

/// Huffman tree node
struct HuffmanNode {
  symbol : Int
  frequency : Int
  left : Int
  right : Int
  parent : Int
}

/// Sort nodes by frequency
fn sort_by_frequency(nodes : Array[HuffmanNode]) -> Array[HuffmanNode] {
  // Simple bubble sort for now
  let mut result = nodes
  for i = 0; i < result.length() - 1; i = i + 1 {
    for j = 0; j < result.length() - 1 - i; j = j + 1 {
      if result[j].frequency > result[j + 1].frequency {
        let temp = result[j]
        result = result.set(j, result[j + 1])
        result = result.set(j + 1, temp)
      }
    }
  }
  result
}

/// Generate Huffman codes from tree
fn generate_codes(node : HuffmanNode, code : Int, bits : Int, nodes : Array[HuffmanNode]) -> Array[HuffmanTableEntry] {
  let mut table = Array::new()
  
  if node.symbol >= 0 {
    // Leaf node
    table = table.append(HuffmanTableEntry {
      symbol: node.symbol
      code: code
      bits: bits
    })
  } else {
    // Internal node
    if node.left >= 0 {
      let left_node = nodes[node.left]
      let left_codes = generate_codes(left_node, code << 1, bits + 1, nodes)
      table = table.append_all(left_codes)
    }
    
    if node.right >= 0 {
      let right_node = nodes[node.right]
      let right_codes = generate_codes(right_node, (code << 1) | 1, bits + 1, nodes)
      table = table.append_all(right_codes)
    }
  }
  
  table
}
