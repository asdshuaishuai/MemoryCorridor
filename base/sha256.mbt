// Independent FIPS 180-4 implementation. No upstream project code is copied.
let constants : Array[UInt] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

fn rotate(x : UInt, n : Int) -> UInt {
  (x >> n) | (x << (32 - n))
}

pub fn sha256_hex(input : Bytes) -> String {
  let data = input.to_array()
  let bits = input.length().to_uint64() * 8UL
  data.push(0x80)
  while data.length() % 64 != 56 { data.push(0) }
  for i = 7; i >= 0; i = i - 1 {
    data.push(((bits >> (i * 8)) & 255UL).to_byte())
  }
  let state : Array[UInt] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]
  for offset = 0; offset < data.length(); offset = offset + 64 {
    let w : Array[UInt] = Array::make(64, 0)
    for i = 0; i < 16; i = i + 1 {
      let p = offset + i * 4
      w[i] = (data[p].to_uint() << 24) | (data[p+1].to_uint() << 16) |
        (data[p+2].to_uint() << 8) | data[p+3].to_uint()
    }
    for i = 16; i < 64; i = i + 1 {
      let x = w[i-15]
      let y = w[i-2]
      w[i] = w[i-16] + (rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)) +
        w[i-7] + (rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10))
    }
    let mut a = state[0]
    let mut b = state[1]
    let mut c = state[2]
    let mut d = state[3]
    let mut e = state[4]
    let mut f = state[5]
    let mut g = state[6]
    let mut h = state[7]
    for i = 0; i < 64; i = i + 1 {
      let t1 = h + (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) +
        ((e & f) ^ ((e ^ 0xffffffff) & g)) + constants[i] + w[i]
      let t2 = (rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) +
        ((a & b) ^ (a & c) ^ (b & c))
      h = g
      g = f
      f = e
      e = d + t1
      d = c
      c = b
      b = a
      a = t1 + t2
    }
    let working = [a,b,c,d,e,f,g,h]
    for i = 0; i < 8; i = i + 1 { state[i] = state[i] + working[i] }
  }
  let out = StringBuilder()
  for word in state {
    for i = 7; i >= 0; i = i - 1 {
      let digit = ((word >> (i * 4)) & 15).reinterpret_as_int()
      out.write_char("0123456789abcdef".get_char(digit).unwrap())
    }
  }
  out.to_string()
}
