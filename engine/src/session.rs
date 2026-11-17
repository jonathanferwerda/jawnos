//! Who counts, when the house is not all there.
//!
//! §12 of `docs/studio-audio-roadmap.md` is the reason this module exists: the
//! clock master is a role, not a machine. A session elects one from the nodes
//! that are armed and able to make samples, so a reboot of `table` costs an
//! election rather than the session. Everything here is pure — no network, no
//! wall clock, no allocation — because the election has to give the same answer
//! on every node that runs it.
//!
//! The caller supplies what each candidate can do and how far away it is; this
//! module only orders them. Nothing here opens a socket or trusts an arrival
//! time (see §10): those belong to the transport, not to the decision.

/// A node's identity inside one session. The manager issues it, and it is the
/// final tiebreak, so two runs over the same candidates elect the same node.
pub type NodeId = u32;

/// One armed node as the election sees it.
///
/// The fields are facts the node declared and the manager measured, not
/// guesses: `inputs`, `rtt_micros` and `has_converter` come from the node
/// registry, and `started_session` records who asked for the session in the
/// first place.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Candidate {
    /// The session's id for this node.
    pub id: NodeId,
    /// True when the node has the house's audio interface. §12 prefers it
    /// first: that machine can be monitored and recorded without a clock
    /// crossing, so it is the least surprising place for the count to live.
    pub has_converter: bool,
    /// How many input channels this node can contribute. More inputs means the
    /// session carries more of the performance directly.
    pub inputs: u16,
    /// True when this node asked for the session. It knows the intent, so it
    /// wins over a peer that merely joined.
    pub started_session: bool,
    /// The measured round trip, in microseconds. Smallest wins: the master's
    /// count reaches that node soonest, so its jitter costs the session least.
    pub rtt_micros: u32,
    /// Armed and answering. A node that is not armed cannot be asked to join,
    /// so it is not a candidate even if it holds the interface.
    pub armed: bool,
}

/// Elect one master, or `None` when nobody can be master.
///
/// The order is §12's, applied lexicographically: the interface, then the most
/// inputs, then the node that started the session, then the smallest round
/// trip, then the smallest node id. The last two comparisons are inverted on
/// purpose — `max_by` keeps the largest key, so "smaller is better" has to
/// compare backwards — which keeps the whole ladder one comparison with no
/// branching and no ambiguity about which rule won.
///
/// The id tiebreak is what makes the answer deterministic: two nodes that are
/// equal on every fact still elect the same master, so a lost election packet
/// cannot make the session change its mind.
///
/// An empty list (or one whose nodes are all unarmed) returns `None`: there is
/// no master, and the caller drops to §12 rung 3, a **session of one** that
/// records against its own clock and reconciles on import. No master is a
/// normal state, not an error.
pub fn elect(candidates: &[Candidate]) -> Option<Candidate> {
    candidates
        .iter()
        .filter(|candidate| candidate.armed)
        .max_by(|a, b| {
            a.has_converter
                .cmp(&b.has_converter)
                .then_with(|| a.inputs.cmp(&b.inputs))
                .then_with(|| a.started_session.cmp(&b.started_session))
                .then_with(|| b.rtt_micros.cmp(&a.rtt_micros))
                .then_with(|| b.id.cmp(&a.id))
        })
        .copied()
}

/// The master's timeline as one node sees it: where the master was when the
/// node's counter read zero, and how fast the node's own clock runs.
///
/// `sample_offset` is `master_sample - local_sample` at the moment of
/// measurement, so positive means the master is ahead. `drift_ppm` is the local
/// clock's rate error in parts per million: positive means the local clock runs
/// fast and has gained that many samples per million on the master.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ClockOffset {
    /// `master_sample - local_sample` at measurement time.
    pub sample_offset: i64,
    /// Local rate error in parts per million; positive means local is fast.
    pub drift_ppm: f64,
}

impl ClockOffset {
    /// Build an offset from a measurement. Kept `const` so a test or a peer
    /// table can hold one without a runtime initialiser.
    pub const fn new(sample_offset: i64, drift_ppm: f64) -> Self {
        ClockOffset {
            sample_offset,
            drift_ppm,
        }
    }

    /// Where `local_sample` sits on the master's timeline.
    ///
    /// A fast local clock (positive drift) has counted *more* samples than the
    /// master for the same elapsed time, so the drift term subtracts:
    /// `local * (1 - drift_ppm / 1e6)`, and then the offset. The result is
    /// signed because at the start of a session a peer may legitimately be
    /// behind the master, and a reconnect needs to place a take before zero.
    pub fn to_master(&self, local_sample: u64) -> i64 {
        let local = local_sample as f64;
        let corrected = local - local * self.drift_ppm / 1_000_000.0;
        self.sample_offset + corrected.round() as i64
    }
}

/// The same correction without naming the struct: `master = local - drift` plus
/// the offset. The reconnect path already has the two numbers from the last
/// timestamped datagram, so it should not have to wrap them first.
pub fn align(local_sample: u64, sample_offset: i64, drift_ppm: f64) -> i64 {
    ClockOffset::new(sample_offset, drift_ppm).to_master(local_sample)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A ready node with no distinguishing facts beyond its id.
    fn node(id: NodeId) -> Candidate {
        Candidate {
            id,
            has_converter: false,
            inputs: 0,
            started_session: false,
            rtt_micros: 5_000,
            armed: true,
        }
    }

    /// A ready node with every fact stated, so a table row names one rung.
    fn cand(
        id: NodeId,
        has_converter: bool,
        inputs: u16,
        started_session: bool,
        rtt_micros: u32,
    ) -> Candidate {
        Candidate {
            id,
            has_converter,
            inputs,
            started_session,
            rtt_micros,
            armed: true,
        }
    }

    fn winner(candidates: &[Candidate]) -> Option<NodeId> {
        elect(candidates).map(|candidate| candidate.id)
    }

    #[test]
    fn an_empty_session_has_no_master() {
        assert_eq!(elect(&[]), None);
    }

    #[test]
    fn a_session_of_unarmed_nodes_has_no_master() {
        let mut interface = node(1);
        interface.has_converter = true;
        interface.armed = false;
        let mut peer = node(2);
        peer.inputs = 64;
        peer.armed = false;
        let both = [interface, peer];
        assert_eq!(elect(&both), None, "rung 3 is the caller's fallback");
    }

    #[test]
    fn an_unarmed_node_is_skipped_even_with_the_interface() {
        let mut interface = node(1);
        interface.has_converter = true;
        interface.armed = false;
        let peer = node(2);
        assert_eq!(winner(&[interface, peer]), Some(2));
    }

    #[test]
    fn every_rung_of_the_ladder_decides_on_its_own() {
        // Each row pits the winner against a node that is better on every rung
        // *below* the one under test, so a regression in that rung flips the
        // answer instead of hiding behind another rule.
        let cases: Vec<(&str, Vec<Candidate>, Option<NodeId>)> = vec![
            (
                "the interface beats inputs, intent and round trip",
                vec![
                    cand(9, true, 1, false, 9_000),
                    cand(1, false, 64, true, 100),
                ],
                Some(9),
            ),
            (
                "the most inputs beats intent and round trip",
                vec![
                    cand(9, false, 2, false, 100),
                    cand(1, false, 8, true, 9_000),
                ],
                Some(1),
            ),
            (
                "the node that started the session beats a shorter round trip",
                vec![
                    cand(9, false, 4, false, 100),
                    cand(1, false, 4, true, 9_000),
                ],
                Some(1),
            ),
            (
                "the smallest round trip beats a smaller id",
                vec![
                    cand(1, false, 4, false, 9_000),
                    cand(9, false, 4, false, 1_200),
                ],
                Some(9),
            ),
            (
                "a full tie falls back to the smallest id",
                vec![
                    cand(7, false, 4, false, 5_000),
                    cand(3, false, 4, false, 5_000),
                    cand(5, false, 4, false, 5_000),
                ],
                Some(3),
            ),
        ];

        for (name, candidates, want) in cases {
            assert_eq!(winner(&candidates), want, "{name}");
        }
    }

    #[test]
    fn the_winner_is_the_candidate_with_the_most_inputs() {
        let quiet = cand(1, false, 1, false, 1);
        let rich = cand(2, false, 12, false, 9_999);
        assert_eq!(elect(&[quiet, rich]), Some(rich));
    }

    #[test]
    fn a_zero_offset_zero_drift_is_the_identity() {
        assert_eq!(align(0, 0, 0.0), 0);
        assert_eq!(align(1, 0, 0.0), 1);
        assert_eq!(align(96_000, 0, 0.0), 96_000);
    }

    #[test]
    fn a_positive_offset_puts_the_master_ahead() {
        assert_eq!(align(1_000, 250, 0.0), 1_250);
        assert_eq!(align(1_000, -250, 0.0), 750);
    }

    #[test]
    fn a_fast_local_clock_maps_backwards() {
        // 1000 ppm on a million samples is a thousand samples gained, so the
        // same local position is a thousand master samples *earlier*.
        assert_eq!(align(1_000_000, 0, 1_000.0), 999_000);
        assert_eq!(align(1_000_000, 0, -1_000.0), 1_001_000);
    }

    #[test]
    fn offset_and_drift_compose() {
        let measured = ClockOffset::new(500, 1_000.0);
        assert_eq!(measured.to_master(1_000_000), 999_500);
        assert_eq!(measured.to_master(0), 500);
    }
}
