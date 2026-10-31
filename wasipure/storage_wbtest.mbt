// Lease takeover only ever follows a provably expired, representable
// expiry: doubles outside the UInt64 domain saturate inside to_uint64()
// (negative → 0, huge → u64::MAX) and must be refused like unreadable
// holders, and expiry at exactly `now` counts as expired.

test "lease expiry rejects values outside the u64 domain" {
  let now : UInt64 = 1_000UL
  // A corrupted/forged negative lockfile must never authorize takeover.
  assert_false(lease_expired(-1.0, now))
  assert_false(lease_expired(-0.5, now))
  assert_false(lease_expired(-1.0e300, now))
  // Beyond 2^64 the saturating conversion would pin u64::MAX; refuse.
  assert_false(lease_expired(1.0e30, now))
  assert_false(lease_expired(18446744073709551616.0, now))
  // Future lease holds; expired lease (and the exact boundary) lets go.
  assert_false(lease_expired(1_001.0, now))
  assert_true(lease_expired(999.0, now))
  assert_true(lease_expired(0.0, now))
  assert_true(lease_expired(1_000.0, now))
}
