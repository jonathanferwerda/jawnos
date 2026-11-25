//! Which device backends this build carries, and which of them this machine
//! can actually use.
//!
//! The crate has no default dependencies, so a machine without ALSA or JACK
//! headers still builds the engine and the null device. `--backends` answers
//! the two different questions honestly: *was the backend compiled in* (ALSA,
//! JACK) and *is a server or PCM present on this machine* (PipeWire)
//! (docs/studio-audio-roadmap.md P1).

use std::env;
use std::fmt;
use std::path::Path;

/// The five ways `--backend` can ask for samples. `Oboe` is Android's
/// low-latency seam; it is capture-only in the first slice and exists only in a
/// `--features oboe` build (docs/studio-oboe-slice.md §2.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    Null,
    Alsa,
    PipeWire,
    Jack,
    Oboe,
}

impl BackendKind {
    /// Parse the word after `--backend`; `None` is a usage error.
    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "null" => Some(BackendKind::Null),
            "alsa" => Some(BackendKind::Alsa),
            "pipewire" => Some(BackendKind::PipeWire),
            "jack" => Some(BackendKind::Jack),
            "oboe" => Some(BackendKind::Oboe),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            BackendKind::Null => "null",
            BackendKind::Alsa => "alsa",
            BackendKind::PipeWire => "pipewire",
            BackendKind::Jack => "jack",
            BackendKind::Oboe => "oboe",
        }
    }

    /// The device a backend will open. PipeWire deliberately always uses the
    /// ALSA `default` PCM, and JACK has no device name of its own.
    pub fn device_name(self, requested: Option<&str>) -> String {
        match self {
            BackendKind::Null => "null".to_string(),
            BackendKind::Alsa => requested.unwrap_or("hw:1,0").to_string(),
            BackendKind::PipeWire => "default".to_string(),
            BackendKind::Jack => "jack".to_string(),
            // The Android HAL names its devices; the string is a label for the
            // report, not a PCM path to open.
            BackendKind::Oboe => requested.unwrap_or("default").to_string(),
        }
    }
}

impl fmt::Display for BackendKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// What `--backends` reports. `alsa`, `jack` and `oboe` are compile-time
/// facts; `pipewire` is a probe of this machine; `null` is always available.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Availability {
    pub alsa: bool,
    pub pipewire: bool,
    pub jack: bool,
    pub oboe: bool,
    pub null: bool,
}

pub fn availability() -> Availability {
    Availability {
        alsa: cfg!(feature = "alsa"),
        pipewire: pipewire_available(),
        jack: cfg!(feature = "jack"),
        oboe: cfg!(feature = "oboe"),
        null: true,
    }
}

/// PipeWire is present when the ALSA `default` PCM opens (it usually points at
/// PipeWire) or when one of its own command-line clients is installed. With no
/// ALSA feature we can only answer the command half, which is honest: the
/// feature is what would let the engine use the PCM anyway.
pub fn pipewire_available() -> bool {
    command_exists("pactl") || command_exists("pw-cli") || probe_default_pcm()
}

#[cfg(feature = "alsa")]
fn probe_default_pcm() -> bool {
    use alsa::pcm::PCM;
    use alsa::Direction;

    // Only open when a sound card or a userspace sound server could plausibly
    // provide `default`. Without either, the open can only fail, and ALSA would
    // print its diagnosis to stderr in the middle of a JSON report.
    if !a_pcm_could_exist() {
        return false;
    }

    // Open and immediately close: no configuration is touched and no stream is
    // left running. Non-blocking keeps a busy device from delaying the report.
    PCM::new("default", Direction::Playback, true).is_ok()
}

/// A local card, PipeWire socket, or PulseAudio socket means `default` may be
/// real. This is a filter for a probe, not a claim about the result.
#[cfg(feature = "alsa")]
fn a_pcm_could_exist() -> bool {
    if Path::new("/dev/snd").exists() {
        return true;
    }
    if let Some(runtime) = env::var_os("XDG_RUNTIME_DIR") {
        let runtime = Path::new(&runtime);
        if runtime.join("pipewire-0").exists() || runtime.join("pulse/native").exists() {
            return true;
        }
    }
    Path::new("/tmp/pipewire-0").exists() || Path::new("/run/pulse/native").exists()
}

#[cfg(not(feature = "alsa"))]
fn probe_default_pcm() -> bool {
    false
}

/// Is `name` an executable somewhere on `PATH`? No shell, no subprocess.
pub fn command_exists(name: &str) -> bool {
    env::var_os("PATH")
        .map(|paths| {
            env::split_paths(&paths).any(|dir| {
                let path = dir.join(name);
                path.is_file() && is_executable(&path)
            })
        })
        .unwrap_or(false)
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;

    path.metadata()
        .map(|meta| meta.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

/// The one JSON line `--backends --json` prints, in the order the contract
/// names the keys.
pub fn json(available: &Availability) -> String {
    format!(
        "{{\"alsa\":{},\"pipewire\":{},\"jack\":{},\"oboe\":{},\"null\":{}}}",
        available.alsa, available.pipewire, available.jack, available.oboe, available.null
    )
}

/// The human report: one line per backend, saying *why* it is or is not there.
pub fn prose(available: &Availability) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "alsa: {}\n",
        if available.alsa {
            "yes (built with --features alsa)"
        } else {
            "no (built without --features alsa)"
        }
    ));
    out.push_str(&format!(
        "pipewire: {}\n",
        if available.pipewire {
            "yes (ALSA default PCM or a PipeWire client is present)"
        } else {
            "no (no ALSA default PCM and no pactl/pw-cli)"
        }
    ));
    out.push_str(&format!(
        "jack: {}\n",
        if available.jack {
            "yes (built with --features jack)"
        } else {
            "no (built without --features jack)"
        }
    ));
    out.push_str(&format!(
        "oboe: {}\n",
        if available.oboe {
            "yes (built with --features oboe)"
        } else {
            "no (built without --features oboe)"
        }
    ));
    out.push_str("null: yes (always available)\n");
    out
}

/// What one `--run` produced. A real backend reports the period and buffer
/// ALSA or JACK actually granted, not necessarily the ones requested.
#[derive(Debug, Clone)]
pub struct RunReport {
    pub backend: &'static str,
    pub device: String,
    pub rate: u32,
    pub frames: usize,
    pub buffer: usize,
    pub channels: usize,
    pub blocks: usize,
    pub samples: usize,
    pub peak: f32,
    pub xruns: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_is_always_available() {
        assert!(availability().null);
    }

    #[test]
    fn the_compile_time_backends_match_the_features() {
        let available = availability();
        assert_eq!(available.alsa, cfg!(feature = "alsa"));
        assert_eq!(available.jack, cfg!(feature = "jack"));
        assert_eq!(available.oboe, cfg!(feature = "oboe"));
    }

    #[test]
    fn parsing_round_trips_and_rejects_nonsense() {
        for kind in [
            BackendKind::Null,
            BackendKind::Alsa,
            BackendKind::PipeWire,
            BackendKind::Jack,
            BackendKind::Oboe,
        ] {
            assert_eq!(BackendKind::parse(kind.name()), Some(kind));
        }
        assert_eq!(BackendKind::parse("banana"), None);
    }

    #[test]
    fn pipewire_always_opens_default_and_alsa_defaults_to_the_interface() {
        assert_eq!(BackendKind::Alsa.device_name(None), "hw:1,0");
        assert_eq!(BackendKind::Alsa.device_name(Some("hw:2,0")), "hw:2,0");
        assert_eq!(BackendKind::PipeWire.device_name(Some("hw:2,0")), "default");
        assert_eq!(BackendKind::Jack.device_name(Some("hw:2,0")), "jack");
        assert_eq!(BackendKind::Oboe.device_name(None), "default");
        assert_eq!(BackendKind::Oboe.device_name(Some("Built-in Mic")), "Built-in Mic");
    }

    #[test]
    fn the_json_names_all_five_backends() {
        let text = json(&availability());
        for key in ["alsa", "pipewire", "jack", "oboe", "null"] {
            assert!(text.contains(&format!("\"{key}\":")), "{text}");
        }
        assert!(text.contains("\"null\":true"), "{text}");
        assert_eq!(text.lines().count(), 1, "{text}");
    }

    #[test]
    fn oboe_is_false_without_the_feature() {
        // The no-feature build is the one the Linux suite runs; the feature
        // build on the phone is what asserts `true` (docs/studio-oboe-slice.md §9).
        assert_eq!(availability().oboe, cfg!(feature = "oboe"));
        assert!(json(&availability()).contains(&format!("\"oboe\":{}", cfg!(feature = "oboe"))));
    }

    #[test]
    fn the_prose_explains_the_oboe_feature() {
        let text = prose(&availability());
        let line = text
            .lines()
            .find(|line| line.starts_with("oboe:"))
            .unwrap_or_else(|| panic!("no oboe line in {text}"));
        if cfg!(feature = "oboe") {
            assert_eq!(line, "oboe: yes (built with --features oboe)");
        } else {
            assert_eq!(line, "oboe: no (built without --features oboe)");
        }
    }

    #[test]
    fn a_known_command_is_found_and_a_silly_one_is_not() {
        #[cfg(unix)]
        assert!(command_exists("sh"));
        assert!(!command_exists("jawn-audio-no-such-command-4f6d"));
    }
}
