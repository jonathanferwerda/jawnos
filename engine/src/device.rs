//! Where samples come from.
//!
//! P1 ships the null device only. It exists so the engine, the graph and the
//! suite run on a machine with no sound card, and so the ALSA/CoreAudio/WASAPI
//! device can be swapped in behind the same trait without touching either
//! (docs/studio-audio-roadmap.md P1).

use std::f32::consts::TAU;

#[derive(Debug, PartialEq, Eq)]
pub enum DeviceError {
    /// The caller's buffer was not `frames * channels` samples long.
    BadBlock { expected: usize, found: usize },
}

/// One device, asked for one block at a time.
pub trait Device {
    fn rate(&self) -> u32;
    fn frames(&self) -> usize;
    fn channels(&self) -> usize;
    /// Fill `block` with one interleaved block of `frames * channels` samples.
    fn process(&mut self, block: &mut [f32]) -> Result<(), DeviceError>;
}

/// A device that never touches hardware: silent, or a sine when asked.
///
/// A tone is how a loopback or a test proves samples moved through the graph; a
/// peak a few thousand blocks long proves the phase carried rather than restarting.
#[derive(Debug)]
pub struct NullDevice {
    rate: u32,
    frames: usize,
    channels: usize,
    tone_hz: Option<f32>,
    phase: f32,
}

impl NullDevice {
    pub fn new(rate: u32, frames: usize, channels: usize) -> Self {
        assert!(rate > 0, "a device needs a sample rate");
        assert!(frames > 0, "a device needs a block size");
        assert!(channels > 0, "a device needs a channel count");
        NullDevice {
            rate,
            frames,
            channels,
            tone_hz: None,
            phase: 0.0,
        }
    }

    pub fn with_tone(mut self, hz: f32) -> Self {
        self.tone_hz = Some(hz);
        self
    }
}

impl Device for NullDevice {
    fn rate(&self) -> u32 {
        self.rate
    }

    fn frames(&self) -> usize {
        self.frames
    }

    fn channels(&self) -> usize {
        self.channels
    }

    fn process(&mut self, block: &mut [f32]) -> Result<(), DeviceError> {
        let expected = self.frames * self.channels;
        if block.len() != expected {
            return Err(DeviceError::BadBlock {
                expected,
                found: block.len(),
            });
        }
        match self.tone_hz {
            None => block.fill(0.0),
            Some(hz) => {
                let step = TAU * hz / self.rate as f32;
                for frame in block.chunks_mut(self.channels) {
                    let sample = self.phase.sin();
                    for out in frame.iter_mut() {
                        *out = sample;
                    }
                    self.phase = (self.phase + step) % TAU;
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_by_default() {
        let mut device = NullDevice::new(48_000, 8, 2);
        let mut block = vec![0.7f32; 16];
        device.process(&mut block).expect("process");
        assert!(block.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn a_tone_reaches_full_scale() {
        let mut device = NullDevice::new(48_000, 512, 1).with_tone(1_000.0);
        let mut block = vec![0.0f32; 512];
        device.process(&mut block).expect("process");
        let loudest = block.iter().fold(0.0f32, |m, s| m.max(s.abs()));
        assert!(loudest > 0.99 && loudest <= 1.0, "peak {loudest}");
    }

    #[test]
    fn the_phase_carries_between_blocks() {
        let mut device = NullDevice::new(48_000, 4, 1).with_tone(1_000.0);
        let mut first = vec![0.0f32; 4];
        let mut second = vec![0.0f32; 4];
        device.process(&mut first).expect("first");
        device.process(&mut second).expect("second");
        assert_ne!(second[0], 0.0, "block two restarted the sine instead of continuing it");
    }

    #[test]
    fn a_wrong_length_is_an_error() {
        let mut device = NullDevice::new(48_000, 8, 2);
        let mut block = vec![0.0f32; 15];
        assert_eq!(
            device.process(&mut block),
            Err(DeviceError::BadBlock {
                expected: 16,
                found: 15
            })
        );
    }

    #[test]
    fn the_reported_shape_is_what_it_was_built_with() {
        let device = NullDevice::new(48_000, 64, 2);
        assert_eq!(device.rate(), 48_000);
        assert_eq!(device.frames(), 64);
        assert_eq!(device.channels(), 2);
    }
}
