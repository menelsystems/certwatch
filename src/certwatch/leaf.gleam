//// Parses CT MerkleTreeLeaf structures (rfc 6962) into certificate info.

import gleam/bit_array
import gleam/result

pub type CertEntry {
  CertEntry(timestamp: Int, domains: List(String))
}

pub fn parse(leaf_b64: String) -> Result(CertEntry, Nil) {
  use bits <- result.try(bit_array.base64_decode(leaf_b64))
  use #(timestamp, der) <- result.try(parse_leaf(bits))
  Ok(CertEntry(timestamp:, domains: domains(der)))
}

/// MerkleTreeLeaf binary layout:
///   version:8   leaf_type:8   timestamp:64
///   entry_type:16   (0 = x509_entry, 1 = precert_entry)
///   x509_entry:    cert_len:24  cert:cert_len bytes  extensions...
///   precert_entry: issuer_key_hash:256  tbs_len:24  tbs:tbs_len bytes  extensions...
/// Returns the timestamp and the DER bytes (full cert, or tbs for precerts).
fn parse_leaf(bits: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bits {
    <<
      _version,
      _leaf_type,
      timestamp:size(64),
      0:size(16),
      len:size(24),
      der:bytes-size(len),
      _:bytes,
    >> -> Ok(#(timestamp, der))
    <<
      _version,
      _leaf_type,
      timestamp:size(64),
      1:size(16),
      _issuer_key_hash:bytes-size(32),
      len:size(24),
      der:bytes-size(len),
      _:bytes,
    >> -> Ok(#(timestamp, der))
    _ -> Error(Nil)
  }
}

/// Extracts dns names from the certificate's subjectAltName extension,
/// using erlang's built-in public_key application. See src/cert_ffi.erl.
@external(erlang, "cert_ffi", "domains")
fn domains(der: BitArray) -> List(String)
