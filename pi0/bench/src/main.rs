// SPDX-License-Identifier: MIT OR Apache-2.0
//
// pi0-bench: CPU micro-benchmarks for the Floresta Pi Zero bench lab.
//
// Prints CSV to stdout, one row per benchmark:
//
//     name,iters,total_ns,ns_per_op,ops_per_sec,extra
//
// `extra` carries a benchmark-specific figure (e.g. MB/s for hashing) or
// is empty.  The shell wrapper (`bench-micro` in the rootfs overlay)
// prepends a header and merges these rows with the SD I/O numbers it
// measures itself with dd.
//
// Iteration counts are fixed, not time-calibrated: on a benchmark box we
// want every run of the same binary to do the exact same work, so two
// CSVs from different boots are directly comparable.  The counts are
// sized for an ARM1176 at 1 GHz — a few seconds per benchmark.

use std::time::Instant;

use bitcoin_hashes::sha256;
use bitcoin_hashes::sha256d;
use bitcoin_hashes::Hash;
use bitcoin_hashes::HashEngine;
use rustreexo::node_hash::BitcoinNodeHash;
use rustreexo::mem_forest::MemForest;
use rustreexo::proof::Proof;
use rustreexo::stump::Stump;
use secp256k1::ecdsa::Signature;
use secp256k1::Message;
use secp256k1::PublicKey;
use secp256k1::Secp256k1;
use secp256k1::SecretKey;

fn report(name: &str, iters: u64, total_ns: u128, extra: String) {
    let ns_per_op = total_ns / u128::from(iters.max(1));
    let ops_per_sec = if total_ns > 0 {
        (u128::from(iters) * 1_000_000_000) / total_ns
    } else {
        0
    };
    println!("{name},{iters},{total_ns},{ns_per_op},{ops_per_sec},{extra}");
}

/// Bulk SHA256: hash 32 MiB fed in 8 KiB chunks.  This approximates
/// hashing transaction data during block validation, and is the
/// benchmark that shows the absence of SHA hardware acceleration on
/// the BCM2835 most directly.
fn bench_sha256_bulk() {
    const CHUNK: usize = 8 * 1024;
    const TOTAL: usize = 32 * 1024 * 1024;
    let chunk = [0xabu8; CHUNK];
    let iters = (TOTAL / CHUNK) as u64;

    let start = Instant::now();
    let mut engine = sha256::HashEngine::default();
    for _ in 0..iters {
        engine.input(&chunk);
    }
    let digest = sha256::Hash::from_engine(engine);
    let total_ns = start.elapsed().as_nanos();

    // Consume the digest so the loop cannot be optimized away.
    assert_ne!(digest.to_byte_array()[0], 0x55);
    let mb_per_sec = (TOTAL as f64 / (1024.0 * 1024.0)) / (total_ns as f64 / 1e9);
    report("sha256_bulk_8k", iters, total_ns, format!("{mb_per_sec:.2}MB/s"));
}

/// Double-SHA256 of an 80-byte block header — the exact operation used
/// for header chain verification.
fn bench_sha256d_header() {
    const ITERS: u64 = 200_000;
    let header = [0x42u8; 80];

    let start = Instant::now();
    let mut acc = 0u8;
    for _ in 0..ITERS {
        let h = sha256d::Hash::hash(&header);
        acc ^= h.to_byte_array()[0];
    }
    let total_ns = start.elapsed().as_nanos();
    assert_ne!(acc, 0xff);
    report("sha256d_header", ITERS, total_ns, String::new());
}

/// ECDSA signature verification over secp256k1 — the dominant cost of
/// full script validation (the path exercised by `--assume-valid 0`).
fn bench_secp256k1_verify() {
    const ITERS: u64 = 500;
    let secp = Secp256k1::new();
    let sk = SecretKey::from_slice(&[0x24u8; 32]).expect("valid key");
    let pk = PublicKey::from_secret_key(&secp, &sk);
    let msg = Message::from_digest(sha256::Hash::hash(b"floresta pi0 bench").to_byte_array());
    let sig: Signature = secp.sign_ecdsa(&msg, &sk);

    let start = Instant::now();
    for _ in 0..ITERS {
        secp.verify_ecdsa(&msg, &sig, &pk).expect("valid signature");
    }
    let total_ns = start.elapsed().as_nanos();
    report("secp256k1_verify", ITERS, total_ns, String::new());
}

fn leaf(i: u64) -> BitcoinNodeHash {
    let mut engine = sha256::HashEngine::default();
    engine.input(&i.to_le_bytes());
    BitcoinNodeHash::from(sha256::Hash::from_engine(engine).to_byte_array())
}

/// Utreexo proof verification against a Stump — what Floresta does for
/// every block's inputs.  We build a 4096-leaf forest once, prove a
/// 64-leaf batch, then verify that proof repeatedly (verification is
/// the node-side hot path; proving happens on bridge nodes).
fn bench_utreexo_verify() {
    const LEAVES: u64 = 4096;
    const BATCH: usize = 64;
    const ITERS: u64 = 500;

    let leaves: Vec<BitcoinNodeHash> = (0..LEAVES).map(leaf).collect();

    let mut forest: MemForest = MemForest::new();
    forest.modify(&leaves, &[]).expect("forest add");

    // Spread the proven batch across the tree instead of taking a
    // contiguous run, so the proof shape is closer to a real block's.
    let targets: Vec<BitcoinNodeHash> = (0..BATCH)
        .map(|i| leaf((i as u64 * 61) % LEAVES))
        .collect();
    let proof: Proof = forest.prove(&targets).expect("prove");

    let (stump, _) = Stump::new()
        .modify(&leaves, &[], &Proof::default())
        .expect("stump add");

    let start = Instant::now();
    for _ in 0..ITERS {
        assert!(stump.verify(&proof, &targets).expect("verify"));
    }
    let total_ns = start.elapsed().as_nanos();
    report(
        "utreexo_verify_64of4096",
        ITERS,
        total_ns,
        format!("{}hashes", proof.hashes.len()),
    );
}

fn main() {
    bench_sha256_bulk();
    bench_sha256d_header();
    bench_secp256k1_verify();
    bench_utreexo_verify();
}
