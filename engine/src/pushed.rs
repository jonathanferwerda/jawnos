//! A live capture whose PCM the app pushes in, for audio that arrives as BLE
//! chunks (the T-Watch and T-Deck microphones) rather than from a local device.
//!
//! [`PushedSource`] is a [`LiveSource`], so a recogniser or the live sender can
//! treat it exactly like a microphone: `rate()` is fixed at construction and
//! `read()` drains the ring oldest-first. Nothing here needs a feature, a C
//! library or sherpa; the bounded ring is plain `std`.
//!
//! # The rate is the source's, never the engine's
//!
//! `capture::start_source` refuses a live source whose rate differs from the
//! take's (`capture.rs`, "a live capture is not resampled to another rate").
//! The pushed source keeps that rule: the constructor declares the rate the
//! chunks were decoded at, and every push must state the same rate
//! ([`PushedSource::push_at`]); a mismatched push is an error, not a resample.
//! The caller learns the declared rate from [`PushedSource::sample_rate`] or
//! the C ABI's `jawn_audio_pushed_rate`.
//!
//! # Overflow: drop the oldest, count it
//!
//! The ring holds a bounded number of frames. A push that would overrun it
//! evicts the oldest unread frames and adds them to [`PushedSource::overwritten`];
//! the newest audio is always what remains, so a reader that falls behind
//! resumes at the live edge instead of replaying stale samples late. `push`
//! accepts the whole block (it returns the block length) and reports evictions
//! only through the counter.
//!
//! # Reading
//!
//! [`LiveSource::read`] blocks for up to [`PUSH_QUIET_MS`] for frames and then
//! returns 0 — which the trait defines as "finished" — so a take attached
//! through `start_source` ends after that much upstream silence. A recogniser
//! that must survive a quiet link polls [`PushedSource::try_read`] instead.
//! [`PushedSource::finish`] ends the source immediately.
//!
//! # The C ABI
//!
//! One process runs one pushed source, exactly as it runs one take
//! (`control.rs`): the ABI has no handle parameter. [`start`] installs the
//! process-wide target that [`push_pcm`] reaches; the functions below it are the
//! plain-C exports the app's JNI shim will call.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use crate::capture::LiveSource;

/// Frames the pushed ring holds by default: 341 ms at 48 kHz, the same
/// headroom as the capture ring the live sender uses.
pub const PUSHED_RING_FRAMES: usize = 16_384;

/// How long [`LiveSource::read`] waits for a push before answering 0. A BLE
/// microphone that has been silent this long is treated as finished; a
/// recogniser that only polls uses [`PushedSource::try_read`] and never waits.
pub const PUSH_QUIET_MS: u64 = 500;

/// `jawn_audio_pushed_open` succeeded.
pub const PUSH_OK: i32 = 0;
/// No pushed source is installed: `jawn_audio_pushed_open` has not run, or
/// `jawn_audio_pushed_close` already ended it.
pub const PUSH_ERR_ABSENT: i32 = -1;
/// A null pointer was passed with a non-zero count/capacity.
pub const PUSH_ERR_NULL: i32 = -2;
/// The push stated a rate other than the source's declared rate.
pub const PUSH_ERR_RATE: i32 = -3;
/// A pushed source is already installed; this process runs one.
pub const PUSH_ERR_STARTED: i32 = -4;
/// The declared rate was zero.
pub const PUSH_ERR_RATE_ZERO: i32 = -5;
/// The count does not fit the ABI's signed return value.
pub const PUSH_ERR_COUNT: i32 = -6;

/// Why a pushed-source call was refused. Every variant has a stable C code in
/// [`PushError::code`], so the ABI carries numbers rather than Rust types.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushError {
    /// No source is installed in this process.
    NotStarted,
    /// A source is already installed; a process runs one.
    AlreadyStarted,
    /// The declared rate was zero.
    ZeroRate,
    /// The push declared a different rate than the source.
    Rate { declared: u32, offered: u32 },
    /// The ABI count does not fit in a non-negative `i32`.
    CountTooLarge,
}

impl PushError {
    /// The negative C status the exported functions return.
    pub fn code(self) -> i32 {
        match self {
            PushError::NotStarted => PUSH_ERR_ABSENT,
            PushError::AlreadyStarted => PUSH_ERR_STARTED,
            PushError::ZeroRate => PUSH_ERR_RATE_ZERO,
            PushError::Rate { .. } => PUSH_ERR_RATE,
            PushError::CountTooLarge => PUSH_ERR_COUNT,
        }
    }
}

impl std::fmt::Display for PushError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PushError::NotStarted => write!(formatter, "no pushed source has started"),
            PushError::AlreadyStarted => write!(formatter, "a pushed source is already started"),
            PushError::ZeroRate => write!(formatter, "a pushed source needs a non-zero rate"),
            PushError::Rate { declared, offered } => write!(
                formatter,
                "the pushed source is {declared} Hz, but the push offered {offered} Hz: a live capture is not resampled to another rate"
            ),
            PushError::CountTooLarge => {
                write!(formatter, "the push count does not fit the ABI's return value")
            }
        }
    }
}

/// The ring state behind one push mutex. The lock is never held by the audio
/// callback; pushes come from the BLE thread and reads from the recogniser or
/// capture thread.
#[derive(Debug)]
struct Ring {
    slots: Vec<i16>,
    /// Index of the oldest unread frame.
    head: usize,
    /// Frames currently held, `0..=capacity`.
    len: usize,
    /// Frames evicted because a push overran the ring.
    overwritten: u64,
}

#[derive(Debug)]
struct Shared {
    rate: u32,
    capacity: usize,
    ring: Mutex<Ring>,
    ready: Condvar,
    finished: AtomicBool,
}

/// A bounded, oldest-first ring fed by [`PushedSource::push`] and drained
/// through [`LiveSource::read`] or [`PushedSource::try_read`]. Clones share the
/// same ring; the first clone may be installed as the process-wide push target.
#[derive(Clone, Debug)]
pub struct PushedSource {
    inner: Arc<Shared>,
}

impl PushedSource {
    /// A source declaring `rate` Hz with the default [`PUSHED_RING_FRAMES`]
    /// capacity. The rate is the rate the caller decodes at; it is never
    /// changed or resampled by the engine.
    pub fn new(rate: u32) -> Self {
        Self::with_capacity(rate, PUSHED_RING_FRAMES)
    }

    /// The same source with an explicit capacity, for a caller that knows its
    /// chunk cadence (and for the tests). A capacity below one is raised to
    /// one.
    pub fn with_capacity(rate: u32, capacity: usize) -> Self {
        let capacity = capacity.max(1);
        PushedSource {
            inner: Arc::new(Shared {
                rate,
                capacity,
                ring: Mutex::new(Ring {
                    slots: vec![0; capacity],
                    head: 0,
                    len: 0,
                    overwritten: 0,
                }),
                ready: Condvar::new(),
                finished: AtomicBool::new(false),
            }),
        }
    }

    /// The rate declared at construction. Every push must match it.
    pub fn sample_rate(&self) -> u32 {
        self.inner.rate
    }

    /// The ring's bound, in frames.
    pub fn capacity(&self) -> usize {
        self.inner.capacity
    }

    /// Offer one block of mono frames. Every frame is accepted; the oldest
    /// unread frames are evicted first if the block overruns the ring, and the
    /// evictions are counted in [`Self::overwritten`]. Returns the number of
    /// frames taken from `samples` (the block length).
    pub fn push(&self, samples: &[i16]) -> usize {
        if samples.is_empty() {
            return 0;
        }
        let capacity = self.inner.capacity;
        {
            let mut ring = self.lock();
            for &sample in samples {
                if ring.len == capacity {
                    ring.head = (ring.head + 1) % capacity;
                    ring.len -= 1;
                    ring.overwritten += 1;
                }
                let slot = (ring.head + ring.len) % capacity;
                ring.slots[slot] = sample;
                ring.len += 1;
            }
        }
        self.inner.ready.notify_all();
        samples.len()
    }

    /// A push that also states the rate it was decoded at. A rate other than
    /// the one declared at construction is [`PushError::Rate`]: the engine does
    /// not resample a live capture (see `capture::start_source`).
    pub fn push_at(&self, samples: &[i16], rate: u32) -> Result<usize, PushError> {
        if rate != self.inner.rate {
            return Err(PushError::Rate {
                declared: self.inner.rate,
                offered: rate,
            });
        }
        Ok(self.push(samples))
    }

    /// Frames waiting to be read.
    pub fn pending(&self) -> usize {
        self.lock().len
    }

    /// Every frame evicted before a reader took it, since construction.
    pub fn overwritten(&self) -> u64 {
        self.lock().overwritten
    }

    /// Copy up to `out.len()` queued frames, oldest first, without waiting.
    /// Returns the frames copied; 0 means the queue is empty right now.
    pub fn try_read(&self, out: &mut [i16]) -> usize {
        if out.is_empty() {
            return 0;
        }
        let mut ring = self.lock();
        self.copy_out(&mut ring, out)
    }

    /// Mark the source finished: a blocked [`LiveSource::read`] wakes and
    /// answers 0, and later reads answer 0 immediately. Queued frames stay
    /// readable through [`Self::try_read`].
    pub fn finish(&self) {
        self.inner.finished.store(true, Ordering::Release);
        self.inner.ready.notify_all();
    }

    /// Whether [`Self::finish`] has been called.
    pub fn is_finished(&self) -> bool {
        self.inner.finished.load(Ordering::Acquire)
    }

    fn lock(&self) -> MutexGuard<'_, Ring> {
        self.inner
            .ring
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn copy_out(&self, ring: &mut Ring, out: &mut [i16]) -> usize {
        let capacity = self.inner.capacity;
        let count = out.len().min(ring.len);
        for (offset, slot) in out.iter_mut().take(count).enumerate() {
            *slot = ring.slots[(ring.head + offset) % capacity];
        }
        ring.head = (ring.head + count) % capacity;
        ring.len -= count;
        count
    }
}

impl LiveSource for PushedSource {
    fn rate(&self) -> u32 {
        self.inner.rate
    }

    /// Drain the ring oldest-first. Waits up to [`PUSH_QUIET_MS`] for a push
    /// when the ring is empty; 0 after that wait (or after
    /// [`PushedSource::finish`]) means the source is finished, per the trait.
    fn read(&mut self, out: &mut [i16]) -> usize {
        if out.is_empty() {
            return 0;
        }
        let mut ring = self.lock();
        while ring.len == 0 && !self.inner.finished.load(Ordering::Acquire) {
            let (next, timed_out) =
                match self
                    .inner
                    .ready
                    .wait_timeout(ring, Duration::from_millis(PUSH_QUIET_MS))
                {
                    Ok((guard, result)) => (guard, result.timed_out()),
                    Err(poisoned) => {
                        let (guard, result) = poisoned.into_inner();
                        (guard, result.timed_out())
                    }
                };
            ring = next;
            if timed_out {
                break;
            }
        }
        self.copy_out(&mut ring, out)
    }
}

/// The process-wide push target, mirroring the one-take [`crate::control`]
/// slot: the C ABI has no handle to pass, so there is one installed source.
static INSTALLED: OnceLock<Mutex<Option<PushedSource>>> = OnceLock::new();

fn installed() -> &'static Mutex<Option<PushedSource>> {
    INSTALLED.get_or_init(|| Mutex::new(None))
}

fn lock_installed() -> MutexGuard<'static, Option<PushedSource>> {
    installed()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Create a pushed source at `rate` and install it as this process's push
/// target. Refused when a rate of zero is declared or a source is already
/// installed; the returned clone is the reader's handle.
pub fn start(rate: u32) -> Result<PushedSource, PushError> {
    start_with_capacity(rate, PUSHED_RING_FRAMES)
}

/// [`start`] with an explicit ring capacity.
pub fn start_with_capacity(rate: u32, capacity: usize) -> Result<PushedSource, PushError> {
    if rate == 0 {
        return Err(PushError::ZeroRate);
    }
    let mut slot = lock_installed();
    if slot.is_some() {
        return Err(PushError::AlreadyStarted);
    }
    let source = PushedSource::with_capacity(rate, capacity);
    *slot = Some(source.clone());
    Ok(source)
}

/// The installed source, if any, as a reader's clone.
pub fn current() -> Option<PushedSource> {
    lock_installed().clone()
}

/// Finish and uninstall the process's pushed source. Returns whether one was
/// installed.
pub fn stop() -> bool {
    let taken = lock_installed().take();
    match taken {
        Some(source) => {
            source.finish();
            true
        }
        None => false,
    }
}

/// Push into the installed source, refusing a rate that differs from its
/// declared rate.
pub fn push(samples: &[i16], rate: u32) -> Result<usize, PushError> {
    match current() {
        Some(source) => source.push_at(samples, rate),
        None => Err(PushError::NotStarted),
    }
}

/// Drain queued frames from the installed source, oldest first, without
/// waiting.
pub fn pull(out: &mut [i16]) -> Result<usize, PushError> {
    match current() {
        Some(source) => Ok(source.try_read(out)),
        None => Err(PushError::NotStarted),
    }
}

// --- the plain-C ABI the app's JNI shim will call -----------------------------

/// Start a process-wide pushed source at `rate` Hz. Returns [`PUSH_OK`] or a
/// negative [`PushError::code`]. A second call while one is installed is
/// `PUSH_ERR_STARTED`; call `jawn_audio_pushed_close` first.
#[no_mangle]
pub extern "C" fn jawn_audio_pushed_open(rate: u32) -> i32 {
    match start(rate) {
        Ok(_) => PUSH_OK,
        Err(error) => error.code(),
    }
}

/// Push `count` mono frames at `rate` into the installed source. Returns the
/// accepted frame count (the whole block) or a negative status:
/// `PUSH_ERR_ABSENT` before start, `PUSH_ERR_NULL` for a null pointer,
/// `PUSH_ERR_RATE` for a rate other than the declared one. A zero `count` is a
/// no-op that returns 0 without requiring a source.
///
/// # Safety
/// `samples` must be null or point to `count` readable `i16` frames.
#[no_mangle]
pub unsafe extern "C" fn jawn_audio_push_pcm(samples: *const i16, count: u32, rate: u32) -> i32 {
    if count == 0 {
        return 0;
    }
    if samples.is_null() {
        return PUSH_ERR_NULL;
    }
    if count > i32::MAX as u32 {
        return PUSH_ERR_COUNT;
    }
    let block = std::slice::from_raw_parts(samples, count as usize);
    match push(block, rate) {
        Ok(accepted) => accepted as i32,
        Err(error) => error.code(),
    }
}

/// Copy up to `capacity` queued frames, oldest first, into `out`. Returns the
/// frames copied (0 when the queue is empty) or a negative status:
/// `PUSH_ERR_ABSENT` before start, `PUSH_ERR_NULL` for a null `out` with a
/// non-zero capacity. A zero capacity returns 0.
///
/// # Safety
/// `out` must be null or point to `capacity` writable `i16` frames.
#[no_mangle]
pub unsafe extern "C" fn jawn_audio_pushed_read(out: *mut i16, capacity: u32) -> i32 {
    if capacity == 0 {
        return 0;
    }
    if out.is_null() {
        return PUSH_ERR_NULL;
    }
    if capacity > i32::MAX as u32 {
        return PUSH_ERR_COUNT;
    }
    let buffer = std::slice::from_raw_parts_mut(out, capacity as usize);
    match pull(buffer) {
        Ok(frames) => frames as i32,
        Err(error) => error.code(),
    }
}

/// The installed source's declared rate, or `PUSH_ERR_ABSENT`.
#[no_mangle]
pub extern "C" fn jawn_audio_pushed_rate() -> i32 {
    match current() {
        Some(source) => source.sample_rate() as i32,
        None => PUSH_ERR_ABSENT,
    }
}

/// Frames the installed source has evicted for overrun, or 0 when none is
/// installed.
#[no_mangle]
pub extern "C" fn jawn_audio_pushed_overwritten() -> u64 {
    current().map(|source| source.overwritten()).unwrap_or(0)
}

/// Finish and uninstall the pushed source. Returns [`PUSH_OK`], or
/// `PUSH_ERR_ABSENT` when none was installed.
#[no_mangle]
pub extern "C" fn jawn_audio_pushed_close() -> i32 {
    if stop() {
        PUSH_OK
    } else {
        PUSH_ERR_ABSENT
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The ABI has one process-wide target, so tests that install it must not
    /// run over each other.
    static ABI: Mutex<()> = Mutex::new(());

    fn abi_lock() -> MutexGuard<'static, ()> {
        ABI.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[test]
    fn a_push_and_read_round_trips_a_known_ramp() {
        let source = PushedSource::with_capacity(48_000, 16);
        let ramp: Vec<i16> = (-6..6).collect();
        assert_eq!(source.push(&ramp), 12);
        assert_eq!(source.pending(), 12);

        let mut first = [0i16; 5];
        assert_eq!(source.try_read(&mut first), 5);
        assert_eq!(first, ramp[..5]);
        assert_eq!(source.pending(), 7);

        let mut rest = [0i16; 16];
        assert_eq!(source.try_read(&mut rest), 7);
        assert_eq!(&rest[..7], &ramp[5..]);
        assert_eq!(source.try_read(&mut rest), 0);
        assert_eq!(source.overwritten(), 0);
    }

    #[test]
    fn a_live_source_read_drains_oldest_first() {
        let mut source = PushedSource::new(48_000);
        assert_eq!(source.rate(), 48_000);
        source.push(&[10, 20, 30]);
        let mut out = [0i16; 2];
        assert_eq!(
            <PushedSource as LiveSource>::read(&mut source, &mut out),
            2
        );
        assert_eq!(out, [10, 20]);
        let mut rest = [0i16; 2];
        assert_eq!(
            <PushedSource as LiveSource>::read(&mut source, &mut rest),
            1
        );
        assert_eq!(rest[0], 30);
    }

    #[test]
    fn an_overflow_drops_the_oldest_and_counts_it() {
        let source = PushedSource::with_capacity(48_000, 4);
        assert_eq!(source.push(&[1, 2, 3, 4, 5, 6]), 6);
        assert_eq!(source.pending(), 4);
        assert_eq!(source.overwritten(), 2);

        let mut out = [0i16; 8];
        assert_eq!(source.try_read(&mut out), 4);
        assert_eq!(&out[..4], &[3, 4, 5, 6], "the newest frames survive");

        assert_eq!(source.push(&[7, 8]), 2);
        assert_eq!(source.try_read(&mut out), 2);
        assert_eq!(&out[..2], &[7, 8]);
        assert_eq!(source.overwritten(), 2);
    }

    #[test]
    fn a_mismatched_rate_is_a_plain_error() {
        let source = PushedSource::new(48_000);
        assert_eq!(
            source.push_at(&[1, 2], 16_000),
            Err(PushError::Rate {
                declared: 48_000,
                offered: 16_000
            })
        );
        assert_eq!(source.pending(), 0, "a refused push kept nothing");
        assert_eq!(source.push_at(&[1, 2], 48_000), Ok(2));
        assert_eq!(source.overwritten(), 0);
    }

    #[test]
    fn a_push_before_start_is_a_harmless_error() {
        let _guard = abi_lock();
        let _ = stop();

        let block = [1i16, 2, 3];
        assert_eq!(
            unsafe { jawn_audio_push_pcm(block.as_ptr(), block.len() as u32, 48_000) },
            PUSH_ERR_ABSENT
        );
        let mut out = [0i16; 4];
        assert_eq!(
            unsafe { jawn_audio_pushed_read(out.as_mut_ptr(), out.len() as u32) },
            PUSH_ERR_ABSENT
        );
        assert_eq!(jawn_audio_pushed_rate(), PUSH_ERR_ABSENT);
        assert_eq!(jawn_audio_pushed_overwritten(), 0);
        assert_eq!(jawn_audio_pushed_close(), PUSH_ERR_ABSENT);
        // A zero-count push needs no source and is not an error.
        assert_eq!(
            unsafe { jawn_audio_push_pcm(std::ptr::null(), 0, 48_000) },
            0
        );
    }

    #[test]
    fn the_abi_round_trips_a_push_and_a_drain() {
        let _guard = abi_lock();
        let _ = stop();

        assert_eq!(jawn_audio_pushed_open(48_000), PUSH_OK);
        assert_eq!(jawn_audio_pushed_rate(), 48_000);
        assert_eq!(jawn_audio_pushed_open(48_000), PUSH_ERR_STARTED);

        let ramp: Vec<i16> = (0..10).collect();
        assert_eq!(
            unsafe { jawn_audio_push_pcm(ramp.as_ptr(), ramp.len() as u32, 48_000) },
            10
        );
        let mut out = [0i16; 4];
        assert_eq!(
            unsafe { jawn_audio_pushed_read(out.as_mut_ptr(), out.len() as u32) },
            4
        );
        assert_eq!(out, [0, 1, 2, 3]);

        let mut rest = [0i16; 8];
        assert_eq!(
            unsafe { jawn_audio_pushed_read(rest.as_mut_ptr(), rest.len() as u32) },
            6
        );
        assert_eq!(&rest[..6], &ramp[4..]);
        assert_eq!(
            unsafe { jawn_audio_pushed_read(rest.as_mut_ptr(), rest.len() as u32) },
            0
        );

        assert_eq!(jawn_audio_pushed_close(), PUSH_OK);
        assert_eq!(jawn_audio_pushed_close(), PUSH_ERR_ABSENT);
        assert_eq!(
            unsafe { jawn_audio_push_pcm(ramp.as_ptr(), 1, 48_000) },
            PUSH_ERR_ABSENT
        );
    }

    #[test]
    fn the_abi_refuses_a_rate_mismatch_and_a_null_pointer() {
        let _guard = abi_lock();
        let _ = stop();

        assert_eq!(jawn_audio_pushed_open(0), PUSH_ERR_RATE_ZERO);
        assert_eq!(jawn_audio_pushed_open(48_000), PUSH_OK);
        let block = [1i16, 2];
        assert_eq!(
            unsafe { jawn_audio_push_pcm(block.as_ptr(), 2, 44_100) },
            PUSH_ERR_RATE
        );
        assert_eq!(
            unsafe { jawn_audio_push_pcm(std::ptr::null(), 2, 48_000) },
            PUSH_ERR_NULL
        );
        let out = [0i16; 4];
        assert_eq!(
            unsafe { jawn_audio_pushed_read(std::ptr::null_mut(), out.len() as u32) },
            PUSH_ERR_NULL
        );
        assert_eq!(
            unsafe { jawn_audio_push_pcm(block.as_ptr(), 2, 48_000) },
            2
        );
        assert_eq!(jawn_audio_pushed_close(), PUSH_OK);
    }

    #[test]
    fn the_abi_counts_overwritten_frames() {
        let _guard = abi_lock();
        let _ = stop();

        assert_eq!(jawn_audio_pushed_open(48_000), PUSH_OK);
        let source = current().expect("the source is installed");
        // Replace the target with a small ring the way a test would: stop the
        // default one, then install a bounded ring through the module API.
        assert_eq!(source.sample_rate(), 48_000);
        assert_eq!(jawn_audio_pushed_close(), PUSH_OK);
        let small = start_with_capacity(48_000, 2).expect("the ring starts");
        assert_eq!(small.push(&[1, 2, 3]), 3);
        assert_eq!(jawn_audio_pushed_overwritten(), 1);
        assert_eq!(jawn_audio_pushed_close(), PUSH_OK);
    }
}
