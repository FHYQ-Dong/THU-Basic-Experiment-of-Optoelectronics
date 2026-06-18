"""
Simplified LDPC error correction simulator for QKD BB84.

What this does
--------------
After Alice fires single photons and Bob measures them, the two sides keep
only events where they happened to use the same polarization basis ("sifting").
The sifted bit strings are *mostly* equal but contain a small fraction of
disagreements ("QBER" — quantum bit error rate) caused by detector dark
counts, misalignment, eavesdropping, etc. This script takes the sifted
bits and runs a (rate-adaptive, multi-round) LDPC error-correction protocol
that — at the cost of leaking some parity information over the public
channel — produces a shared key string with QBER ≈ 0.

Pipeline
--------
1. Load CSV → sift (drop wrong-basis events) → produce Alice/Bob bit arrays.
2. Build LDPC parity-check matrices for every code rate in `CODE_RATE` once,
   reusing them for all blocks.
3. For each block of N bits:
   a. Pick the best code rate for that block's measured QBER.
   b. Compute Alice's syndrome = H · errors (where errors = Alice XOR Bob,
      using the simulation shortcut of knowing the true errors — in a real
      protocol Alice would send only the syndrome).
   c. Run min-sum belief propagation. If it doesn't converge in MAX_ITER,
      disclose the `disclose_num` least-confident bits (their true values)
      and retry, up to MAX_ROUNDS rounds.
   d. Record convergence, final QBER on the key bits, leakage efficiency.
4. Print per-block summaries and an aggregate report.

Input CSV format (one row per single-photon event):
    seq,channel_mapped,txt_value,match
  - seq: event timestamp (unused here, only kept for traceability)
  - channel_mapped: Alice's channel index (0-3) → bit = channel_mapped % 2
  - txt_value: Bob's channel index (0-3) → bit = txt_value % 2
  - match: 0 = bases didn't match (discard); 1 = matched & agreed;
           -1 = matched & disagreed (real QBER event)

Usage
-----
    python ecc_simplified.py <events.csv> [--qber QBER] [-N BLOCK_SIZE]

Dependencies: numpy, scipy, sympy
"""

import argparse
import csv
import logging
import math
import time
from pathlib import Path

import numpy as np
from scipy import sparse
import sympy

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Block size. 2520 = 2^3 · 3^2 · 5 · 7 — divisible by every LINE_WEIGHT below,
# so an LDPC matrix can be constructed for any code rate in the table.
N_BLOCK = 2520

# Available code rates R (key bits per block / total bits per block). Higher R
# = less parity leaked, but only tolerates lower QBER. The rate-selection logic
# picks the highest R whose Shannon limit still leaves margin for the block's
# measured QBER.
CODE_RATE   = np.array([9/10, 5/6, 4/5, 11/15, 5/7, 2/3, 3/5, 5/9, 1/2])
# Row weight L of the QC-LDPC base matrix for each rate. (J = (1-R)·L = column
# weight; both are tuned so the code performs well near its capacity.)
LINE_WEIGHT = np.array([40,   24,  20,  15,    14,  12,  10,  9,   8], dtype=int)

# Min-sum scaling factor (normalized min-sum decoder); 0.75 is a common value
# for short LDPC codes — compensates for min-sum's overestimation of magnitudes.
ALPHA_MS = np.float32(0.75)
# LLR magnitude assigned to "shortened" bits — they're known to be 0, so we
# express near-certainty without using literal infinity (which would NaN the
# arithmetic).
LLR_SHORT = 1000.0
MAX_ITER   = 300   # BP iterations per round (in blocks of 10, with early exit)
MAX_ROUNDS = 20    # Max multi-round disclosure passes per block
EPS_Q      = 1e-12 # Floor for QBER to avoid log(0)


# ---------------------------------------------------------------------------
# LDPC matrix construction (QC-LDPC, same algorithm as ldpcdecoder.py)
# ---------------------------------------------------------------------------
# We build the parity-check matrix H in two stages:
#   1. A "core" base matrix of size (J·p × L·p), a J×L array of cyclic shift
#      identities — small but with the right column/row weights (J, L).
#   2. Repeated QC (quasi-cyclic) expansion by prime factors q, each step
#      replaces every 1 with a q×q cyclic-shifted identity (shift depends on
#      i, j to keep girth large). This blows up the matrix size by ×q while
#      preserving J and L.
# Final shape: (J · p · ∏q × L · p · ∏q) = (J·M × L·M = J·N/L × N).
#
# The factor choice (p, then q's) maximizes girth — picking p so the leftover
# factor of M has small prime factors gives a smoother expansion ladder.

def _prime_factors(n):
    """Return prime factors with multiplicity, sorted ascending."""
    return [p for p, exp in sympy.factorint(int(n)).items() for _ in range(exp)]


def _construct_ldpc_matrix(N, J, L):
    """Build a QC-LDPC parity-check matrix of shape (J·N/L) × N.

    Args:
        N: codeword length (must be divisible by L)
        J: column weight (= number of 1s per column)
        L: row weight  (= number of 1s per row)
    """
    def construct_core(J, L, p):
        # Stage 1: J×L array of p×p cyclic-shifted identities. Shift for block
        # (i, j) is (i·j) mod p — a standard QC-LDPC layered construction.
        Q = np.zeros((J * p, L * p), dtype=np.int8)
        I  = np.arange(J)[:, None, None]
        Jc = np.arange(L)[None, :, None]
        r  = np.arange(p)[None, None, :]
        s  = (I * Jc) % p                              # shift per block
        rows = (I * p + (r + s) % p).reshape(-1)
        cols = np.broadcast_to(Jc * p + r, (J, L, p)).reshape(-1)
        Q[rows, cols] = 1
        return Q

    def qc_expand(H, q):
        # Stage 2: replace each 1 at (i, j) by a q×q permutation matrix whose
        # shift S = (i² + j² + i·j) mod q. The polynomial mixing kills short
        # cycles that a naive shift schedule would create.
        H = (H != 0)
        m, n = H.shape
        H_new = np.zeros((m * q, n * q), dtype=np.int8)
        ij = np.argwhere(H)
        if ij.size == 0:
            return H_new
        i, j = ij[:, 0], ij[:, 1]
        S = (i**2 + j**2 + i * j) % q
        r = np.arange(q)[None, :]
        row_idx = (i[:, None] * q + r).reshape(-1)
        col_idx = (j[:, None] * q + (r + S[:, None]) % q).reshape(-1)
        H_new[row_idx, col_idx] = 1
        return H_new

    if N % L != 0:
        raise ValueError(f'N={N} not divisible by L={L}')
    M = N // L  # Number of column-blocks; total expansion factor across all stages.

    # Choose p (size of stage-1 cyclic block): the leftover M/p will be split
    # into q's. We pick the p that makes M/p's smallest prime factor as large
    # as possible (smoother factor ladder ⇒ better girth in expansion).
    best_p, best_score = None, -1
    for p in range(L + 1, M + 1):
        if M % p != 0:
            continue
        rem = M // p
        score = float('inf') if rem == 1 else min(_prime_factors(rem))
        if score > best_score:
            best_score, best_p = score, p

    # Stage 2 expansions go largest factor first (empirically better girth).
    q_factors = sorted(_prime_factors(M // best_p), reverse=True) if M // best_p > 1 else []
    H = construct_core(J, L, best_p)
    for q in q_factors:
        H = qc_expand(H, q)
    assert H.shape[1] == N, f'N mismatch: expected {N}, got {H.shape[1]}'
    return H


def _precompute_upa_order(H):
    """Untainted Puncturing Algorithm (UPA): pick puncture/shorten candidates.

    Returns a column-index ordering such that the prefix [:k] is a "good" set
    of bits to puncture or shorten (low connectivity to each other → erasing
    them confuses BP the least). Used by `select_rate_and_indices`.

    Algorithm: repeatedly pick the lowest-degree untainted variable (degree
    counted in H^T H, i.e., how many parity checks two vars share). Mark it
    and all its neighbors as "tainted" so the next pick is structurally
    independent. Fill any remaining slots in degree order.
    """
    H_csr = sparse.csr_matrix((H != 0).astype(np.float32))
    n = H_csr.shape[1]
    # G[i, j] = number of parity checks involving both variable i and j.
    G = (H_csr.T @ H_csr).tocsr()
    G.sort_indices()
    deg2 = np.diff(G.indptr)  # G's per-row nnz = number of structural neighbors
    indptr, indices = G.indptr, G.indices

    untainted = np.ones(n, dtype=bool)
    selected = []
    while untainted.any():
        masked = np.where(untainted, deg2, np.iinfo(deg2.dtype).max)
        cands = np.where(untainted & (deg2 == masked.min()))[0]
        if cands.size == 0:
            break
        sel = int(cands[0])
        selected.append(sel)
        # Taint the picked variable and all its co-check neighbors.
        untainted[sel] = False
        untainted[indices[indptr[sel]:indptr[sel + 1]]] = False

    # If tainting exhausted vars before we picked all n, append the rest in
    # ascending degree (least connected first).
    if len(selected) < n:
        sel_set = np.zeros(n, dtype=bool)
        sel_set[selected] = True
        rem = np.where(~sel_set)[0]
        selected.extend(rem[np.argsort(deg2[rem], kind='stable')].tolist())

    return np.array(selected, dtype=np.int64)


def build_all_matrices(N, log):
    """Build H, H_csr, UPA order for compatible code rates (N % L == 0)."""
    H_csr_list, upa_list = [], []
    n_rates = len(CODE_RATE)
    for i in range(n_rates):
        L = int(LINE_WEIGHT[i])
        if N % L != 0:
            H_csr_list.append(None)
            upa_list.append(None)
            log.debug('Rate %d/%d (R=%.3f, L=%d): skipped (N%%L!=0)', i+1, n_rates, CODE_RATE[i], L)
            continue
        J = int(round((1 - CODE_RATE[i]) * LINE_WEIGHT[i]))
        t = time.time()
        H = _construct_ldpc_matrix(N, J, L)
        H_csr_list.append(sparse.csr_matrix(H.astype(np.float32)))
        upa_list.append(_precompute_upa_order(H))
        log.debug('Rate %d/%d (R=%.3f, J=%d, L=%d): %.1fs', i+1, n_rates, CODE_RATE[i], J, L, time.time()-t)
    return H_csr_list, upa_list


# ---------------------------------------------------------------------------
# Rate selection and index computation
# ---------------------------------------------------------------------------

def select_rate_and_indices(N, qber, H_csr_list, upa_list):
    """Pick a code rate for this block's QBER, then split the N positions into
    {puncture, shorten, key} sets using the precomputed UPA ordering.

    Reconciliation efficiency f = (bits leaked) / (N · h(QBER)). f=1 means we
    leak exactly the Shannon bound; >1 means we leak more (necessary overhead).
    For each rate R, we solve for puncturing fraction π and shortening fraction σ
    that target f ≈ 1, then pick the highest rate that *can* hit f ≥ 1
    (best efficiency), or — if none can — the rate closest to f = 1.

    Returns: (chosen_rate, rate_idx, H_csr, punctured_idx, shortened_idx, key_idx)
      - punctured: bits removed from transmission, decoded as erasures (LLR=0)
      - shortened: bits fixed to 0 at both ends (LLR = ±LLR_SHORT)
      - key:       the remaining "real" bits that become the shared key
    """
    he = -qber * math.log2(qber) - (1 - qber) * math.log2(1 - qber)  # h₂(QBER)
    # Maximum allowed puncture+shorten budget — third of the block here.
    n_sp = N // 3

    def eval_rate(idx, R):
        # Algebraic solution for π, σ targeting reconciliation efficiency = 1
        # given rate R and entropy h_e. Negative solutions clamped to 0.
        denom_sp = he - 1
        if abs(denom_sp) < 1e-15:
            return None
        pi = max(0, (he - 1 + R) / denom_sp)
        sigma = max(0, 1 - (1 - R) / he)
        s_c, p_c = math.ceil(n_sp * sigma), math.ceil(n_sp * pi)
        denom = (N - p_c - s_c) * he
        if denom <= 0:
            return None
        f_start = (N * (1 - R) - p_c) / denom  # initial reconciliation eff.
        return (idx, float(R), s_c, p_c, f_start)

    # Prefer rates that achieve f ≥ 1 (i.e., enough parity to actually correct
    # at this QBER), then among those pick the one with smallest f (tightest =
    # least leakage = best efficiency).
    best = None
    for idx, R in enumerate(CODE_RATE):
        if H_csr_list[idx] is None:
            continue
        r = eval_rate(idx, R)
        if r is None:
            continue
        if r[4] >= 1.0 and (best is None or r[4] < best[4]):
            best = r
    # Fallback: if nothing reaches f ≥ 1 (very high QBER), take the rate with
    # the largest f (closest to feasible) and rely on multi-round disclosure.
    if best is None:
        for idx, R in enumerate(CODE_RATE):
            if H_csr_list[idx] is None:
                continue
            r = eval_rate(idx, R)
            if r is None:
                continue
            if best is None or r[4] > best[4]:
                best = r
    if best is None:
        raise ValueError('No suitable code rate found')

    idx, cr, s, p = best[0], best[1], best[2], best[3]
    # First s+p positions from the UPA order = best candidates to puncture/shorten.
    # Randomly assign s of them to "shorten", the rest to "puncture".
    punc_short = upa_list[idx][:s + p]
    rng = np.random.default_rng()
    shortened_idx = rng.choice(punc_short, size=s, replace=False)
    punctured_idx = punc_short[~np.isin(punc_short, shortened_idx)]
    key_mask = np.ones(N, dtype=bool)
    key_mask[shortened_idx] = False
    key_mask[punctured_idx] = False
    key_idx = np.where(key_mask)[0].astype(np.int64)
    return cr, idx, H_csr_list[idx], punctured_idx, shortened_idx, key_idx


# ---------------------------------------------------------------------------
# Min-sum BP decoder
# ---------------------------------------------------------------------------

def bp_decode(H_csr, syndrome, errors, key_idx, shortened_idx, punctured_idx,
              qber, max_iter=MAX_ITER):
    """Normalized min-sum belief propagation, syndrome-decoding flavor.

    Decodes the error vector e (one bit per variable node) given:
      - H_csr     : parity-check matrix (M × N)
      - syndrome  : s = H · e mod 2 (length M, treated as Alice's "leaked" info)
      - errors    : current best-known error pattern (used as channel prior)
      - key_idx   : positions whose prior LLR encodes the channel (QBER)
      - shortened : positions known to be 0 → very large LLR with right sign
      - punctured : positions unknown        → LLR = 0 (erasures)

    Iteration loop (Tanner graph, edge-based):
      * v→c message: variable's belief minus the incoming c→v on this edge
      * c→v message: normalized min-sum — sign = product of v→c signs along
        the row, magnitude = (2nd min if this edge has the min |v→c|, else
        the min) scaled by ALPHA_MS, then flipped per syndrome bit.

    Convergence check every 10 iterations: re-evaluate H · ê and stop early
    if the syndrome matches (fully decoded) or if the |LLR| sum stagnates
    (no further progress).
    """
    M, N = H_csr.shape
    indptr, indices, nnz = H_csr.indptr, H_csr.indices, H_csr.nnz
    row_counts = np.diff(indptr)

    # Each parity row's syndrome bit flips the sign of every outgoing c→v
    # message on that row's edges (so a "1" syndrome demands an odd parity).
    sign_vec = np.where((syndrome & 1) == 0, np.float32(1), np.float32(-1))
    edge_signs = np.repeat(sign_vec, row_counts)

    # Prior LLR per variable. Convention: LLR > 0 ⇒ believes bit = 0.
    # llr0 = log((1-q)/q): magnitude of certainty given the channel QBER.
    llr0 = float(math.log2((1 - qber) / max(qber, EPS_Q)))
    L_int = np.zeros(N, dtype=np.float32)
    # Key bits: prior depends on `errors` initial guess (typically 0 for round 1,
    # nonzero for disclosed bits in later rounds).
    L_int[key_idx]       = llr0      * (1 - 2 * errors[key_idx].astype(np.float32))
    # Punctured: no info, will be inferred purely from check messages.
    L_int[punctured_idx] = 0.0
    # Shortened: known with high confidence.
    L_int[shortened_idx] = LLR_SHORT * (1 - 2 * errors[shortened_idx].astype(np.float32))

    msg_v2c = L_int[indices].copy()           # length nnz, indexed by edge
    msg_c2v = np.zeros(nnz, dtype=np.float32)
    L_total = np.zeros(N, dtype=np.float32)

    # Pad each parity row to max-width so we can vectorize per-row ops with
    # uniform shape (M × max_rw). `mask` marks the real (non-padding) entries.
    max_rw = int(row_counts.max())
    edge_pad = np.zeros((M, max_rw), dtype=np.int64)
    mask = np.zeros((M, max_rw), dtype=bool)
    for i in range(M):
        rw = int(row_counts[i])
        edge_pad[i, :rw] = np.arange(indptr[i], indptr[i + 1])
        mask[i, :rw] = True
    mask_flat = mask.ravel()
    arange_M = np.arange(M)

    s_target  = (syndrome & 1).astype(np.float32)
    sad_denom = float(max(N - len(shortened_idx), 1))  # normalize SAD across non-shortened
    r_judge   = np.zeros(5, dtype=np.float32)          # rolling history of |LLR| sums
    converged = False
    actual_it = 0

    # Outer loop in groups of 10 BP iterations; check convergence between groups.
    for it_block in range(0, max_iter, 10):
        n_it = min(10, max_iter - it_block)
        for _ in range(n_it):
            # ── Check-node update (normalized min-sum) ──────────────────────
            v2c = np.where(mask, msg_v2c[edge_pad], 0.0)
            abs_v = np.where(mask, np.abs(v2c), np.inf)
            # Two smallest |v2c| per row — we substitute "min on the same edge"
            # by the 2nd-min to keep the partial-product property of min-sum.
            part = np.partition(abs_v, 1, axis=1)
            min1, min2 = part[:, 0], part[:, 1]
            is_min = np.zeros_like(mask)
            is_min[arange_M, np.argmin(abs_v, axis=1)] = True
            sgn = np.where(mask, np.where(v2c >= 0, np.float32(1), np.float32(-1)), np.float32(1))
            sgn_prod = np.prod(sgn, axis=1)                  # row-wise product of signs
            mag = np.where(is_min, min2[:, None], min1[:, None])
            # Outgoing c→v: divide-out this edge from the sign product, take
            # the appropriate min, scale, then apply syndrome sign flip.
            c2v = (sgn_prod[:, None] * sgn) * mag * ALPHA_MS
            msg_c2v[edge_pad.ravel()[mask_flat]] = c2v.ravel()[mask_flat]
            msg_c2v *= edge_signs

            # ── Variable-node update + tentative posterior ─────────────────
            L_total[:] = L_int
            np.add.at(L_total, indices, msg_c2v)             # sum of all c→v + prior
            msg_v2c[:] = L_total[indices] - msg_c2v          # subtract this edge

        actual_it = it_block + n_it

        # Tentative hard decision and syndrome check (early termination).
        bits = (L_total < 0).astype(np.float32)
        syn  = np.asarray(H_csr.dot(bits)).ravel()
        syn_err = float(np.max(np.abs(syn % 2 - s_target)))
        sad = float(np.sum(np.abs(L_total))) / sad_denom

        if syn_err < 0.1:
            converged = True
            break
        # Stagnation: if |LLR| sum stopped growing past iteration 20, give up.
        r_mean = float(np.mean(r_judge))
        if actual_it >= 20 and sad < r_mean:
            break
        r_judge[(actual_it // 10 - 1) % 5] = sad

    decode_bits = (L_total < 0).astype(np.int8)
    return decode_bits, converged, L_total, actual_it


# ---------------------------------------------------------------------------
# Single-block decode (with multi-round disclose)
# ---------------------------------------------------------------------------

def decode_one_block(block_idx, alice, bob, N, qber_override,
                     H_csr_list, upa_list, log):
    """
    Run full multi-round LDPC correction on one block.
    Logs per-round detail to `log`. Returns a result dict.

    Multi-round disclosure strategy: if BP fails to converge, disclose the
    `disclose_num` least-confident bits' true values (move them from "key"
    to "shortened") and retry. Each round leaks more parity but typically
    breaks deadlock. Up to MAX_ROUNDS rounds.
    """
    # Simulation shortcut: we know the true errors because we have both Alice
    # and Bob's bits. In a real protocol Alice computes the syndrome locally
    # and sends only that.
    true_errors = (alice ^ bob).astype(np.int8)
    block_qber = float(true_errors.sum()) / N
    qber = qber_override if qber_override is not None else block_qber

    # No errors → nothing to do, the whole block becomes raw key.
    if block_qber < EPS_Q:
        log.info('[Block %d] QBER=0, skipping', block_idx)
        return {
            'ok': True, 'block_qber': 0.0, 'final_qber': 0.0,
            'efficiency': 1.0, 'disclose_rounds': 0,
            'key_bits_out': N, 'bp_iters_total': 0, 'time': 0.0,
        }

    he = -qber * math.log2(qber) - (1 - qber) * math.log2(1 - qber)

    # Pick the highest rate that can decode this QBER, plus the puncture
    # / shorten / key partition of N positions.
    cr, _rate_idx, H_csr, p_idx, s_idx, k_idx = select_rate_and_indices(
        N, qber, H_csr_list, upa_list,
    )
    p_num_0, s_num_0 = len(p_idx), len(s_idx)
    k_idx_0 = k_idx.copy()  # Save initial key positions for final QBER computation.
    # Per-round disclosure budget: scales inversely with rate (lower rate ⇒
    # already leaking more, so disclose fewer extras per round).
    disclose_num = max(1, int(math.ceil(N * (0.028 - 0.02 * cr))))

    log.info('[Block %d] QBER=%.6f  code_rate=%.4f  punctured=%d  shortened=%d  '
             'key=%d  disclose/rnd=%d',
             block_idx, block_qber, cr, p_num_0, s_num_0, len(k_idx), disclose_num)

    # Syndrome that Alice would send. Mod 2 because H is binary.
    syndrome = (H_csr.dot(true_errors.astype(np.float32)).astype(np.int64) % 2).astype(np.int8)

    errors = np.zeros(N, dtype=np.int8)         # Bob's running guess of the error pattern
    key_idx       = k_idx.copy()
    shortened_idx = s_idx.copy()
    punctured_idx = p_idx.copy()
    bp_iters_total = 0
    t_start = time.time()

    for rnd in range(1, MAX_ROUNDS + 1):
        # ── BP attempt with current key/short/punct partition ───────────────
        t1 = time.time()
        decoded, ok, L_total, iters = bp_decode(
            H_csr, syndrome, errors, key_idx, shortened_idx, punctured_idx, qber,
        )
        dt = time.time() - t1
        bp_iters_total += iters
        residual = int((decoded ^ true_errors).sum())  # remaining wrong bits vs ground truth
        log.info('[Block %d]   Round %d: BP_iters=%d  converged=%s  residual=%d  time=%.2fs',
                 block_idx, rnd, iters, ok, residual, dt)

        if ok:
            # Success: compute final QBER on the original key positions, and
            # the information-theoretic leakage efficiency.
            final_qber = float(decoded[k_idx_0].sum()) / k_idx_0.size
            # Bits leaked = parity bits + disclosed bits in past rounds.
            leaked = N * (1 - cr) - p_num_0 + disclose_num * (rnd - 1)
            key_total = N - p_num_0 - s_num_0
            f_eff = leaked / (key_total * he) if (key_total * he) > 0 else float('inf')
            # "efficiency" here is the residual secret-key fraction after
            # PA-style accounting; values close to 1 are best.
            efficiency = 1.0 - he / (1 - he) * (f_eff - 1.0) if he < 1 else 0.0
            total_time = time.time() - t_start

            log.info('[Block %d]   => OK  final_qber=%.6f  efficiency=%.4f  '
                     'disclose_rounds=%d  key_left=%d  total_time=%.2fs',
                     block_idx, final_qber, efficiency, rnd - 1, key_idx.size, total_time)
            return {
                'ok': True, 'block_qber': block_qber, 'final_qber': final_qber,
                'efficiency': efficiency, 'disclose_rounds': rnd - 1,
                'key_bits_out': int(key_idx.size), 'bp_iters_total': bp_iters_total,
                'time': total_time,
            }

        # ── BP failed: pick least-confident bits, disclose their truth ─────
        # |L_total| small ⇒ BP is most unsure here ⇒ best ROI to reveal.
        # Move those bits from key → shortened (now known with high confidence).
        disclose_idx = np.argsort(np.abs(L_total))[:disclose_num]
        errors[disclose_idx] = true_errors[disclose_idx]
        key_idx       = key_idx[~np.isin(key_idx, disclose_idx)]
        shortened_idx = np.concatenate([shortened_idx, disclose_idx])
        punctured_idx = punctured_idx[~np.isin(punctured_idx, disclose_idx)]
        disc_errs = int(true_errors[disclose_idx].sum())
        log.info('[Block %d]   Round %d: disclosed %d bits (%d errs), key_remaining=%d',
                 block_idx, rnd, disclose_num, disc_errs, key_idx.size)

    total_time = time.time() - t_start
    log.warning('[Block %d]   => FAILED after %d rounds  total_time=%.2fs',
                block_idx, MAX_ROUNDS, total_time)
    return {
        'ok': False, 'block_qber': block_qber, 'final_qber': float('nan'),
        'efficiency': 0.0, 'disclose_rounds': MAX_ROUNDS,
        'key_bits_out': 0, 'bp_iters_total': bp_iters_total,
        'time': total_time,
    }


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def load_csv(path):
    """Read events CSV, sift (discard match==0), return alice_bits and bob_bits.

    Sifting = throw out events where Alice and Bob used different bases
    (encoded as match==0). The remaining events form the raw key on each side:
    the channel index → bit mapping is channel % 2 (channels 0/2 → 0,
    channels 1/3 → 1; see the BB84 polarization convention in
    `Alice/random-gen.py` and the FPGA `laser_ctrl.v`).
    """
    alice_ch, bob_ch, matches = [], [], []
    with open(path, newline='') as f:
        for row in csv.DictReader(f):
            alice_ch.append(int(row['channel_mapped']))
            bob_ch.append(int(row['txt_value']))
            matches.append(int(row['match']))
    alice_ch = np.array(alice_ch)
    bob_ch   = np.array(bob_ch)
    matches  = np.array(matches)

    total     = len(matches)
    sift_mask = matches != 0                # keep matched-basis events only
    n_sifted  = int(sift_mask.sum())
    n_match   = int((matches == 1).sum())   # agreed (no error)
    n_error   = int((matches == -1).sum())  # disagreed (real bit error)

    stats = {
        'total': total, 'sifted': n_sifted,
        'correct': n_match, 'error': n_error,
        'raw_qber': n_error / n_sifted if n_sifted > 0 else 0.0,
    }
    alice_bits = (alice_ch[sift_mask] % 2).astype(np.int8)
    bob_bits   = (bob_ch[sift_mask]   % 2).astype(np.int8)
    return alice_bits, bob_bits, stats


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description='QKD BB84 simplified LDPC error correction')
    parser.add_argument('csv_file', help='Events CSV (seq,channel_mapped,txt_value,match)')
    parser.add_argument('--qber', type=float, default=None, help='QBER estimate (auto-detect per block if omitted)')
    parser.add_argument('-N', type=int, default=N_BLOCK, help=f'Block size (default {N_BLOCK})')
    parser.add_argument('--log', type=str, default=None, help='Log file path (default: <csv_stem>_ecc.log)')
    args = parser.parse_args()
    N = args.N

    csv_path = Path(args.csv_file)
    log_path = Path(args.log) if args.log else csv_path.with_name(csv_path.stem + '_ecc.log')

    # Set up file logger
    log = logging.getLogger('ecc')
    log.setLevel(logging.DEBUG)
    fh = logging.FileHandler(log_path, mode='w', encoding='utf-8')
    fh.setFormatter(logging.Formatter('%(asctime)s  %(message)s', datefmt='%H:%M:%S'))
    log.addHandler(fh)

    # Load and sift
    alice_all, bob_all, sift_stats = load_csv(args.csv_file)
    n_sifted = sift_stats['sifted']
    n_blocks = n_sifted // N

    print(f'CSV: {csv_path.name}')
    print(f'  Events: {sift_stats["total"]}  Sifted: {n_sifted}  '
          f'Raw QBER: {sift_stats["raw_qber"]:.6f}')
    print(f'  Block size N={N}  Blocks: {n_blocks}  '
          f'Unused tail: {n_sifted - n_blocks * N} bits')
    if n_blocks == 0:
        print(f'Error: not enough sifted bits for even 1 block (need >= {N})')
        return
    print(f'  Log file: {log_path}')

    log.info('CSV: %s', csv_path.name)
    log.info('Events=%d  Sifted=%d  Correct=%d  Error=%d  RawQBER=%.6f',
             sift_stats['total'], n_sifted, sift_stats['correct'],
             sift_stats['error'], sift_stats['raw_qber'])
    log.info('N=%d  Blocks=%d  QBER_override=%s', N, n_blocks, args.qber)

    # Build LDPC matrices (once)
    print(f'\nBuilding LDPC matrices (N={N})...', end=' ', flush=True)
    t0 = time.time()
    H_csr_list, upa_list = build_all_matrices(N, log)
    build_t = time.time() - t0
    print(f'{build_t:.1f}s')
    log.info('Matrix build time: %.1fs', build_t)

    # Process blocks
    print(f'\n{"Block":>5}  {"QBER":>8}  {"Status":>6}  {"Eff":>6}  '
          f'{"Rounds":>6}  {"KeyOut":>6}  {"Time":>6}')
    print('-' * 56)

    results = []
    t_all = time.time()
    for bi in range(n_blocks):
        start = bi * N
        a_block = alice_all[start:start + N]
        b_block = bob_all[start:start + N]
        res = decode_one_block(bi, a_block, b_block, N, args.qber,
                               H_csr_list, upa_list, log)
        results.append(res)

        status = 'OK' if res['ok'] else 'FAIL'
        print(f'{bi:>5}  {res["block_qber"]:>8.4f}  {status:>6}  '
              f'{res["efficiency"]:>6.3f}  {res["disclose_rounds"]:>6}  '
              f'{res["key_bits_out"]:>6}  {res["time"]:>5.1f}s')

    t_total = time.time() - t_all

    # Aggregate summary
    ok_results = [r for r in results if r['ok']]
    fail_results = [r for r in results if not r['ok']]
    n_ok = len(ok_results)
    n_fail = len(fail_results)

    avg_qber = np.mean([r['block_qber'] for r in results]) if results else 0
    avg_eff = np.mean([r['efficiency'] for r in ok_results]) if ok_results else 0
    avg_rounds = np.mean([r['disclose_rounds'] for r in ok_results]) if ok_results else 0
    total_key_in = n_blocks * N
    total_key_out = sum(r['key_bits_out'] for r in results)
    total_bp = sum(r['bp_iters_total'] for r in results)

    summary = f"""
{'='*56}
  Summary: {n_blocks} blocks ({n_ok} OK, {n_fail} FAIL)
{'='*56}
  Input sifted bits  = {n_sifted}
  Blocks processed   = {n_blocks}  (N={N})
  Avg block QBER     = {avg_qber:.6f}
  Success rate       = {n_ok}/{n_blocks} ({100*n_ok/n_blocks:.1f}%)
  Avg efficiency     = {avg_eff:.4f}
  Avg disclose rounds= {avg_rounds:.1f}
  Total key out      = {total_key_out} bits  ({100*total_key_out/total_key_in:.1f}% of input)
  Total BP iters     = {total_bp}
  Total time         = {t_total:.1f}s  ({t_total/n_blocks:.2f}s/block)
{'='*56}"""
    print(summary)
    log.info(summary)


if __name__ == '__main__':
    main()
