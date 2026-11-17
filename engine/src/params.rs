//! Parameters the control thread writes and the audio thread reads.
//!
//! One relaxed atomic per parameter carrying an `f32`'s bits: no lock, no
//! allocation, and no torn read. The audio thread never blocks, so a knob turned
//! during a block is heard at the next block's edge — which, at 64 frames, is
//! 1.33 ms, and is exactly why the block is small.

use std::sync::atomic::{AtomicU32, Ordering};

#[derive(Debug)]
pub struct Param(AtomicU32);

impl Param {
    pub const fn new(value: f32) -> Self {
        Param(AtomicU32::new(value.to_bits()))
    }

    #[inline]
    pub fn get(&self) -> f32 {
        f32::from_bits(self.0.load(Ordering::Relaxed))
    }

    #[inline]
    pub fn set(&self, value: f32) {
        self.0.store(value.to_bits(), Ordering::Relaxed);
    }
}

impl Default for Param {
    fn default() -> Self {
        Param::new(0.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;

    #[test]
    fn stores_and_loads_a_float() {
        let param = Param::new(0.25);
        assert_eq!(param.get(), 0.25);
        param.set(-1.5);
        assert_eq!(param.get(), -1.5);
    }

    #[test]
    fn is_shared_across_threads() {
        let param = Arc::new(Param::new(0.0));
        let writer = Arc::clone(&param);
        let worker = thread::spawn(move || {
            for i in 0..10_000 {
                writer.set(i as f32);
            }
        });
        worker.join().expect("writer");
        assert_eq!(param.get(), 9_999.0);
    }

    #[test]
    fn default_is_silence() {
        assert_eq!(Param::default().get(), 0.0);
    }
}
