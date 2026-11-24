//! A tiny deterministic PRNG, so noise and pluck excitation need no crate.
//!
//! xorshift64* is seeded per voice from a counter in the synth. Two runs of the
//! same event sequence therefore draw the same numbers and produce the same
//! samples. `sin`, `tan` and `exp` still come from the platform's libm, so
//! bit-identical output is guaranteed for the same binary, not across CPU
//! architectures.

/// A 64-bit xorshift generator with a multiply scramble.
pub(crate) struct Rng {
    state: u64,
}

impl Rng {
    /// Seed a generator. Zero is remapped, because xorshift never leaves it.
    pub fn new(seed: u64) -> Self {
        Rng { state: seed | 1 }
    }

    /// The next 64 random bits.
    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// A sample in `[-1, 1)`, the shape `Math.random() * 2 - 1` produces.
    pub fn next_bipolar(&mut self) -> f32 {
        // 24 bits is exactly a float's mantissa; 2/2^24 keeps it in [-1, 1).
        let unit = (self.next_u64() >> 40) as f32 / 8_388_608.0;
        unit - 1.0
    }
}

#[cfg(test)]
mod tests {
    use super::Rng;

    #[test]
    fn deterministic_and_bounded() {
        let mut a = Rng::new(7);
        let mut b = Rng::new(7);
        for _ in 0..1000 {
            let x = a.next_bipolar();
            assert_eq!(x, b.next_bipolar());
            assert!((-1.0..1.0).contains(&x));
        }
        assert_ne!(Rng::new(7).next_u64(), Rng::new(8).next_u64());
    }
}
