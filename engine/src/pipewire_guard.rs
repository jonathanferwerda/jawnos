//! Keep a PipeWire playback stream out of the sink the engine captures.
//!
//! The PipeWire backend opens the ALSA `default` PCM, so the only thing that
//! decides where the stream lands is `PIPEWIRE_NODE` (which the ALSA plugin
//! copies to `target.object`). If that target is missing, is `default`, or the
//! graph refuses it, the stream falls back to the default sink — and while the
//! engine is capturing the system mix, the default sink *is* the mix sink. A
//! capture played back into its own input at unity gain is an oscillator: the
//! burst, then the teardown.
//!
//! So the guard does two things. Before the PCM opens it refuses a target it
//! cannot trust (none, `default`, or the sink itself). After the stream exists
//! it reads `pw-link -l` and refuses a link that lands on the mix sink, or a
//! playback stream that did not reach the named target at all. Refusing is the
//! point: the engine stops the pass and says why, rather than playing into the
//! default because an environment variable went unhonoured.

use std::ffi::OsStr;
use std::process::Command;
use std::time::Duration;

/// The node-name prefix the PipeWire ALSA plugin gives a playback stream:
/// `alsa_playback.<program name>`.
pub const ENGINE_PLAYBACK_PREFIX: &str = "alsa_playback.";

/// Every guard refusal carries this so the caller can report it as the
/// system-mix verdict rather than a generic device failure.
pub const FEEDBACK_PREFIX: &str = "playback guard: ";

/// `pipewire-alsa` reports a playback stream whose server-side link was lost
/// as `EIO` from `snd_pcm_writei`. `snd_pcm_recover` does not handle it (it
/// only knows underrun, suspend and interruption), but the link is not the
/// device: a fresh PipeWire stream can be linked to the same target again.
/// This is the one write error a patch reopens its PCM for, rather than
/// treating the whole pass as failed.
pub const LINK_LOST_ERRNO: i32 = 5; // EIO

/// How long one block keeps trying to reopen its PCM after a lost link. A
/// server reconfiguration (WirePlumber re-linking a device, a change of graph
/// quantum) can take a moment; this rides one out, while a target that has
/// really gone still ends the pass instead of spinning on it.
pub const LINK_LOST_RECOVERY_MS: u64 = 2_000;

/// The pause between reopen attempts inside that window.
pub const LINK_LOST_RETRY_MS: u64 = 200;

/// Whether a write error is the lost-link case, identified by errno alone.
pub fn link_lost(errno: i32) -> bool {
    errno == LINK_LOST_ERRNO
}

/// Whether one more reopen is allowed. `elapsed_ms` is how long the current
/// block has been trying since its first lost link.
pub fn reopen_after_link_loss(errno: i32, elapsed_ms: u64) -> bool {
    link_lost(errno) && elapsed_ms < LINK_LOST_RECOVERY_MS
}

/// The one guard refusal that is not a verdict: a stream WirePlumber has not
/// linked yet. A reopen after a lost link creates a new stream, and the target
/// may be about to come back (or the link may simply not have been published);
/// the reopen retries that instead of treating it as feedback or a wrong
/// output. The dangerous verdicts carry "feedback loop" or name another node.
pub fn awaiting_link(error: &str) -> bool {
    error.contains("no graph link")
}

/// The sink a system-mix source belongs to. `jawn_system.monitor` is a source
/// on the `jawn_system` sink; a name that is not a monitor is left alone.
pub fn mix_sink(source: &str) -> Option<&str> {
    let source = source.trim();
    if source.is_empty() {
        return None;
    }
    Some(source.strip_suffix(".monitor").unwrap_or(source))
}

/// The node part of a `node:port` name from `pw-link -l`.
pub fn port_node(port: &str) -> &str {
    match port.rsplit_once(':') {
        Some((node, _port)) => node,
        None => port,
    }
}

/// The links `pw-link -l` describes, as `(output, input)` port pairs. The
/// output listing groups a node header with one indented arrow per link:
///
/// ```text
/// alsa_playback.jawn-audio:output_FL
///   |-> alsa_output.pci-0000_00_1f.3.analog-stereo:playback_FL
/// ```
///
/// An input-grouped listing writes `|<- output` under the input port; both
/// shapes are accepted.
pub fn link_pairs(listing: &str) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    let mut current: Option<String> = None;
    for raw in listing.lines() {
        let line = raw.trim();
        if line.is_empty() {
            current = None;
            continue;
        }
        if let Some(rest) = line.strip_prefix("|->") {
            let rest = rest.trim();
            if let (Some(output), false) = (&current, rest.is_empty()) {
                pairs.push((output.clone(), rest.to_string()));
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("|<-") {
            let rest = rest.trim();
            if let (Some(input), false) = (&current, rest.is_empty()) {
                pairs.push((rest.to_string(), input.clone()));
            }
            continue;
        }
        current = Some(line.to_string());
    }
    pairs
}

/// One guarded PipeWire pass: the output the engine was told to play through,
/// and the sink it must never play into.
#[derive(Debug, Clone)]
pub struct PlaybackGuard {
    target: String,
    sink: String,
}

impl PlaybackGuard {
    /// Refuse to build a guard unless a real output was named. `default` is the
    /// sink the system mix just made the machine's default, so accepting it is
    /// the bug this type exists to stop.
    pub fn new(target: Option<&str>, system_device: &str) -> Result<Self, String> {
        let sink = mix_sink(system_device)
            .ok_or_else(|| format!("{FEEDBACK_PREFIX}the system mix source is empty"))?
            .to_string();
        let target = target.unwrap_or("").trim();
        if target.is_empty() || target == "default" {
            return Err(format!(
                "{FEEDBACK_PREFIX}the system mix is captured from {sink}, but no output to play through was named; refusing to open the default sink, which is that mix"
            ));
        }
        if target == sink || target == format!("{sink}.monitor") {
            return Err(format!(
                "{FEEDBACK_PREFIX}the requested output {target} is the sink this pass captures; refusing to create a feedback loop"
            ));
        }
        Ok(Self {
            target: target.to_string(),
            sink,
        })
    }

    pub fn target(&self) -> &str {
        &self.target
    }

    pub fn sink(&self) -> &str {
        &self.sink
    }

    /// Set the target before the PCM opens. `PIPEWIRE_NODE` is the ALSA
    /// plugin's own key; setting it here rather than trusting an inherited
    /// value is what makes the environment explicit.
    pub fn arm(&self) {
        if std::env::var_os("PIPEWIRE_NODE").as_deref() != Some(OsStr::new(&self.target)) {
            std::env::set_var("PIPEWIRE_NODE", &self.target);
        }
    }

    /// Check one `pw-link -l` listing. A link from this engine's playback node
    /// into the mix sink is a loop; a playback stream that reached some other
    /// node is a target that was not honoured. Both are refusals.
    pub fn check(&self, listing: &str) -> Result<(), String> {
        let pairs = link_pairs(listing);
        let playback: Vec<&(String, String)> = pairs
            .iter()
            .filter(|(output, _)| output.starts_with(ENGINE_PLAYBACK_PREFIX))
            .collect();
        let monitor = format!("{}.monitor", self.sink);
        for (output, input) in &playback {
            let node = port_node(input);
            if node == self.sink || node == monitor {
                return Err(format!(
                    "{FEEDBACK_PREFIX}{output} is linked into {input}, the sink this pass captures; refusing to run a feedback loop"
                ));
            }
        }
        if playback.is_empty() {
            return Err(format!(
                "{FEEDBACK_PREFIX}the playback stream has no graph link yet; {target} was not honoured",
                target = self.target
            ));
        }
        // A numeric target is an object id, which `pw-link -l` prints as a
        // node name. There is nothing to compare without a second lookup; the
        // loop check above is the safety property in that case.
        let named = self.target.parse::<u32>().is_err();
        if named
            && !playback
                .iter()
                .any(|(_, input)| port_node(input) == self.target)
        {
            let landed = playback
                .iter()
                .map(|(_, input)| port_node(input))
                .collect::<Vec<_>>()
                .join(", ");
            return Err(format!(
                "{FEEDBACK_PREFIX}the playback stream is linked to {landed}, not {target}; refusing to run on another output",
                target = self.target
            ));
        }
        Ok(())
    }

    /// Read the live graph and check it. A machine without `pw-link` cannot be
    /// asked: the engine runs, and the supervisor's own probe still breaks a
    /// loop if one forms. If the tool exists but the server does not answer,
    /// there is no graph to loop through either.
    pub fn verify(&self) -> Result<(), String> {
        // The stream is created during PCM prepare, but the session manager may
        // publish the link a moment later. Poll briefly rather than refuse a
        // good pass on a scheduling race.
        let mut last = None;
        for attempt in 0..20 {
            let Some(listing) = live_links() else {
                return Ok(());
            };
            match self.check(&listing) {
                Ok(()) => return Ok(()),
                Err(error) => last = Some(error),
            }
            if attempt < 19 {
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        Err(last.unwrap_or_else(|| format!("{FEEDBACK_PREFIX}no playback link was found")))
    }
}

/// `pw-link -l`, or `None` when the tool cannot answer here.
fn live_links() -> Option<String> {
    let output = Command::new("pw-link").arg("-l").output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    const LOOP: &str = "\
jawn_system:monitor_FL
  |-> parec:input_FL

alsa_playback.jawn-audio:output_FL
  |-> jawn_system:playback_FL
";

    const GOOD: &str = "\
jawn_system:monitor_FL
  |-> parec:input_FL

alsa_playback.jawn-audio:output_FL
  |-> alsa_output.real:playback_FL
";

    #[test]
    fn a_lost_pipewire_link_is_the_error_a_reopen_handles() {
        assert!(link_lost(LINK_LOST_ERRNO));
        // EPIPE (32) is an underrun `snd_pcm_recover` fixes in place; EINVAL
        // (22) is a programming or configuration error a reopen cannot fix.
        assert!(!link_lost(32));
        assert!(!link_lost(22));
        assert!(reopen_after_link_loss(LINK_LOST_ERRNO, 0));
        assert!(reopen_after_link_loss(
            LINK_LOST_ERRNO,
            LINK_LOST_RECOVERY_MS - LINK_LOST_RETRY_MS
        ));
        assert!(!reopen_after_link_loss(
            LINK_LOST_ERRNO,
            LINK_LOST_RECOVERY_MS
        ));
        assert!(!reopen_after_link_loss(32, 0));
    }

    #[test]
    fn an_unlinked_reopen_is_retried_not_refused() {
        let guard =
            PlaybackGuard::new(Some("alsa_output.real"), "jawn_system.monitor").expect("a guard");
        let waiting = guard.check("").expect_err("no link yet");
        assert!(awaiting_link(&waiting), "{waiting}");
        let looped = guard.check(LOOP).expect_err("a link into the mix sink");
        assert!(!awaiting_link(&looped), "{looped}");
        let elsewhere = guard
            .check("alsa_playback.jawn-audio:output_FL\n  |-> alsa_output.usb:playback_FL\n")
            .expect_err("another output");
        assert!(!awaiting_link(&elsewhere), "{elsewhere}");
    }

    #[test]
    fn a_monitor_source_names_the_sink_it_belongs_to() {
        assert_eq!(mix_sink("jawn_system.monitor"), Some("jawn_system"));
        assert_eq!(mix_sink("jawn_system"), Some("jawn_system"));
        assert_eq!(mix_sink("  "), None);
    }

    #[test]
    fn a_link_listing_is_read_in_both_directions() {
        let pairs = link_pairs(LOOP);
        assert!(pairs.contains(&(
            "alsa_playback.jawn-audio:output_FL".to_string(),
            "jawn_system:playback_FL".to_string()
        )));
        let input_grouped = "\
jawn_system:playback_FL
  |<- alsa_playback.jawn-audio:output_FL
";
        assert_eq!(
            link_pairs(input_grouped),
            vec![(
                "alsa_playback.jawn-audio:output_FL".to_string(),
                "jawn_system:playback_FL".to_string()
            )]
        );
    }

    #[test]
    fn a_missing_or_default_target_is_refused_before_opening() {
        assert!(PlaybackGuard::new(None, "jawn_system.monitor").is_err());
        assert!(PlaybackGuard::new(Some("default"), "jawn_system.monitor").is_err());
        assert!(PlaybackGuard::new(Some("jawn_system"), "jawn_system.monitor").is_err());
        assert!(PlaybackGuard::new(Some("jawn_system.monitor"), "jawn_system.monitor").is_err());
        assert!(PlaybackGuard::new(Some("alsa_output.real"), "jawn_system.monitor").is_ok());
    }

    #[test]
    fn the_graph_check_refuses_the_sink_it_captures() {
        let guard = PlaybackGuard::new(Some("jawn_system"), "jawn_system.monitor")
            .expect_err("the mix sink is refused before the graph");
        assert!(guard.contains("feedback loop"), "{guard}");

        let guard = PlaybackGuard::new(Some("alsa_output.real"), "jawn_system.monitor")
            .expect("a real output");
        let error = guard.check(LOOP).expect_err("a link into the mix sink");
        assert!(error.contains("feedback loop"), "{error}");
    }

    #[test]
    fn a_working_graph_is_left_alone() {
        let guard =
            PlaybackGuard::new(Some("alsa_output.real"), "jawn_system.monitor").expect("a guard");
        assert!(guard.check(GOOD).is_ok());
    }

    #[test]
    fn a_stream_that_landed_elsewhere_is_refused() {
        let guard =
            PlaybackGuard::new(Some("alsa_output.real"), "jawn_system.monitor").expect("a guard");
        let elsewhere = "\
alsa_playback.jawn-audio:output_FL
  |-> alsa_output.usb:playback_FL
";
        let error = guard.check(elsewhere).expect_err("the named target was not honoured");
        assert!(error.contains("not alsa_output.real"), "{error}");
    }

    #[test]
    fn a_playback_stream_with_no_link_is_refused() {
        let guard =
            PlaybackGuard::new(Some("alsa_output.real"), "jawn_system.monitor").expect("a guard");
        let error = guard.check("").expect_err("no link");
        assert!(error.contains("no graph link"), "{error}");
    }
}
