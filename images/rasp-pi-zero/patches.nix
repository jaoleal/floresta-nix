# SPDX-License-Identifier: MIT OR Apache-2.0
#
# What has to change in Floresta's *source* to build for this board —
# and nothing else.  Pure data: a shell fragment run as `postPatch`.
#
# Kept apart from ./toolchain.nix (how to cross-compile) and ./node.nix
# (what to build) on purpose: this is the file that changes every time
# upstream moves, and it must be able to change without invalidating the
# toolchain or ../microbench.nix.
#
# Every entry here is a workaround with an expiry date.  When upstream
# fixes one, delete it — do not let this file become folklore.
{
  # bitcoinkernel is DISABLED for this board (for now): floresta-node
  # hard-wires the feature, and libbitcoinkernel's build.rs
  # dylib=stdc++ emission is what kept breaking static linking on this
  # target (besides dragging a full Bitcoin Core C++ build into every
  # compile).  Without it, florestad uses floresta's own Rust
  # validation path — which is the native thing this bench lab wants to
  # measure anyway.  Revisit when rust-bitcoinkernel's cxx_runtime()
  # handles crt-static.
  # NOTE: this string is part of the node's derivation hash.  Reflowing
  # a comment inside it triggers a full ARMv6 rebuild — do not rewrap.
  postPatch = ''
    # Cargo feature unification: ONE enabler anywhere in the
    # graph compiles bitcoinkernel for everyone.  Both hard-wired
    # sites must go (floresta-node and floresta-electrum).
    substituteInPlace crates/floresta-node/Cargo.toml \
      --replace-fail 'floresta-chain = { workspace = true, features = ["bitcoinkernel"] }' \
                     'floresta-chain = { workspace = true }'
    substituteInPlace crates/floresta-electrum/Cargo.toml \
      --replace-fail 'floresta-chain = { workspace = true, features = ["bitcoinkernel"] }' \
                     'floresta-chain = { workspace = true }'

    # 32-bit fix: the flat chainstore's default capacity of
    # 10,000,000 blocks rounds to 2^24 slots x 128-byte entries
    # = exactly 2^31 bytes of mmap — one byte past isize::MAX on
    # a 32-bit target ("memory map length overflows isize" at
    # startup, florestad dead on arrival).  2,000,000 rounds to
    # 2^21 slots = a 256MB map: decades of mainnet headroom and
    # comfortably mappable on ARMv6.  The value lives in TWO
    # places: FlatChainStoreConfig::new()'s explicit Some(...)
    # (the one florestad actually hits) and the unwrap_or
    # fallbacks.  Patch both, loudly.  Worth an upstream issue:
    # the default should be clamped for 32-bit targets.
    substituteInPlace crates/floresta-chain/src/pruned_utreexo/flat_chain_store.rs \
      --replace-fail 'headers_file_size: Some(10_000_000),' \
                     'headers_file_size: Some(2_000_000),' \
      --replace-fail 'block_index_size: Some(10_000_000),' \
                     'block_index_size: Some(2_000_000),' \
      --replace-fail '.unwrap_or(Self::truncate_to_pow2(10_000_000));' \
                     '.unwrap_or(Self::truncate_to_pow2(2_000_000));'
  '';
}
