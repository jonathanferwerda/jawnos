//! One Channel's plan, read from JSON, for a capture take that runs the strip.
//!
//! `docs/studio-oboe-slice.md` §9 item 3 runs one fixture — a `tone` insert then
//! a `delay` insert — through the same [`Channel`] on Linux and on the phone.
//! The plan is the bytes that name which strip ran; the knobs are exactly the
//! names [`Channel::set_insert`] takes, so a plan cannot drift from the control
//! path:
//!
//! ```json
//! {"gain":1.0,"pan":0.0,
//!  "tone":{"bass":0.0,"mid":0.0,"treble":0.0,"gain":1.0},
//!  "delay":{"time":0.20,"feedback":0.25,"vol":0.45}}
//! ```
//!
//! An empty string, `null`, or a missing plan is the raw path and builds no
//! channel. The object's key order is the chain order; an explicit
//! `"inserts":["tone","delay"]` array may fix it instead, and the objects then
//! supply that insert's knobs. `"name"` is the sidecar's label; without one the
//! label is the chain (`tone+delay`) or `raw`.
//!
//! This module is always compiled: the parser and the fixture's unit test do
//! not need the Oboe feature, so the Linux half of the gate runs on every
//! machine. It adds no dependency; the JSON grammar is the small one this file
//! documents (objects, arrays, strings, numbers, `true`/`false`/`null`).

use crate::effect::{Channel, InsertKind};

/// The fixture every side of the gate runs: trim at unity, the tone stack at
/// noon, and the DM-2 at 200 ms / 0.25 feedback / 0.45 wet.
///
/// The delay is long enough that its first repeat sits clear of the tone
/// stack's own short tail, which is what makes the fixture's echo measurable
/// from a live take as well as from the Linux impulse test. Both the engine's
/// ABI (`jawn_audio_fixture_plan`) and the test below read this one string.
pub const FIXTURE_PLAN: &str = concat!(
    "{\"gain\":1.0,\"pan\":0.0,",
    "\"tone\":{\"bass\":0.0,\"mid\":0.0,\"treble\":0.0,\"gain\":1.0},",
    "\"delay\":{\"time\":0.20,\"feedback\":0.25,\"vol\":0.45}}"
);

/// One insert in the plan, with its knobs in the order the plan named them.
#[derive(Debug, Clone, PartialEq)]
pub struct PlanInsert {
    pub kind: InsertKind,
    /// `(control, value)` exactly as [`Channel::set_insert`] expects the
    /// control's name and the native unit.
    pub knobs: Vec<(String, f32)>,
}

impl PlanInsert {
    fn new(kind: InsertKind) -> Self {
        PlanInsert {
            kind,
            knobs: Vec::new(),
        }
    }
}

/// One Channel's plan: the strip's own two knobs, the input it reads, its
/// inserts in order, and the song's master rack after them.
#[derive(Debug, Clone, PartialEq)]
pub struct ChannelPlan {
    /// The device input this strip reads: `0` is the left/mic channel and `1`
    /// the right/instrument channel of the engine's stereo capture. A plan that
    /// names no `channel` reads 0, exactly as every plan did before the field.
    pub input: usize,
    /// Clamped to [`Channel::MAX_GAIN`] when read.
    pub gain: f32,
    /// Clamped to -1..=1. It is carried for the report and for a future stereo
    /// path; a mono take has no second channel to place it in.
    pub pan: f32,
    pub inserts: Vec<PlanInsert>,
    /// The master rack, after the channel strip and its pan. Empty is no rack,
    /// which is what every plan before the field described.
    pub master: Vec<PlanInsert>,
    /// The sidecar's label, when the plan named one.
    pub name: Option<String>,
}

impl ChannelPlan {
    /// The label the report and the sidecar carry: the plan's `name`, else the
    /// chain the plan builds.
    pub fn label(&self) -> String {
        match &self.name {
            Some(name) if !name.is_empty() => name.clone(),
            _ if self.inserts.is_empty() => "raw".to_string(),
            _ => self
                .inserts
                .iter()
                .map(|insert| insert.kind.name())
                .collect::<Vec<&str>>()
                .join("+"),
        }
    }

    /// The master rack's names in chain order, e.g. `master_comp+master_limiter`.
    /// Empty when the plan carries no master inserts.
    pub fn master_label(&self) -> String {
        self.master
            .iter()
            .map(|insert| insert.kind.master_prefix().unwrap_or(insert.kind.name()))
            .collect::<Vec<&str>>()
            .join("+")
    }

    /// Build the channel this plan describes. Allocation happens here, on the
    /// setup thread, never in an audio callback.
    pub fn channel(&self) -> Channel {
        let mut channel = Channel::new(self.gain, self.pan);
        for insert in &self.inserts {
            channel.push(insert.kind.build());
            for (knob, value) in &insert.knobs {
                // Every knob was validated against the kind's control list when
                // the plan was read; a false here would mean the map and the
                // parser disagree, so it is a programming error, not input.
                debug_assert!(
                    channel.set_insert(insert.kind.name(), knob, *value),
                    "validated knob {}.{knob} was refused",
                    insert.kind.name()
                );
            }
        }
        channel
    }
}

/// The take's optional strip: one plan's Channel, plus the block buffers it
/// reuses. Built on the setup thread ([`Strip::new`]) so `prepare` allocates
/// once; [`Strip::process`] then runs a captured block with no allocation.
///
/// The ring carries both captured channels. Without a plan this writes the
/// left sample unchanged — the raw path. With a plan it reads the plan's
/// `channel`, runs the channel's trim and inserts in place and still writes one
/// channel: a mono WAV stays mono, so the plan's `pan` is carried and reported
/// but has no second channel to place it in. The master rack is not part of the
/// WAV: a take is one channel of the song and the rack runs once at mixdown.
pub struct Strip {
    channel: Option<Channel>,
    /// The frame sample this strip reads: the plan's `channel`. A plan that
    /// named none reads 0, exactly as the strip always did.
    input: usize,
    left: Vec<f32>,
}

impl Strip {
    pub fn new(plan: Option<ChannelPlan>, rate: u32, period: usize) -> Self {
        let period = period.max(1);
        let input = plan.as_ref().map_or(0, |plan| plan.input);
        let channel = plan.map(|plan| {
            let mut channel = plan.channel();
            channel.prepare(rate, period);
            channel
        });
        Strip {
            channel,
            input,
            left: vec![0.0f32; period],
        }
    }

    /// True when a plan built a channel; false on the raw path.
    pub fn is_stripped(&self) -> bool {
        self.channel.is_some()
    }

    /// Turn `got` frames of the stereo ring into the mono block the WAV takes.
    /// `mono` must hold at least `got` samples.
    pub fn process(&mut self, stereo: &[f32], mono: &mut [i16], got: usize) {
        let got = got.min(self.left.len()).min(mono.len());
        for (slot, frame) in self.left.iter_mut().zip(stereo.chunks_exact(2)).take(got) {
            *slot = frame.get(self.input).copied().unwrap_or(frame[0]);
        }
        if let Some(channel) = self.channel.as_mut() {
            // `got` never exceeds the prepared period (the ring pop is sized to
            // it), so this cannot fail; if it ever did, the block would be
            // written raw rather than dropped from the take.
            let _ = channel.process_mono(&mut self.left[..got]);
        }
        for (slot, value) in mono.iter_mut().zip(&self.left[..got]) {
            *slot = to_s16(*value);
        }
    }
}

/// f32 back to S16 exactly as the capture divided by 32768: multiplying by the
/// same undoes it for every i16 value, so the raw path is bit-exact.
fn to_s16(value: f32) -> i16 {
    (value * 32768.0).round().clamp(-32768.0, 32767.0) as i16
}

/// Read one plan. `None` is the raw path: a null pointer, an empty/blank
/// string, or the JSON literal `null`. A malformed plan is an error sentence
/// naming what was wrong, so a refused take never half-arms a strip.
pub fn parse_plan(text: Option<&str>) -> Result<Option<ChannelPlan>, String> {
    let text = match text {
        None => return Ok(None),
        Some(text) if text.trim().is_empty() => return Ok(None),
        Some(text) => text,
    };
    let value = Parser::new(text).parse_value()?;
    match value {
        Json::Null => Ok(None),
        Json::Object(fields) => parse_object(fields).map(Some),
        _ => Err("the plan must be one JSON object".to_string()),
    }
}

fn parse_object(fields: Vec<(String, Json)>) -> Result<ChannelPlan, String> {
    let mut input = 0usize;
    let mut gain = 1.0f32;
    let mut pan = 0.0f32;
    let mut name = None;
    let mut order: Vec<String> = Vec::new();
    let mut knobs: Vec<(String, Vec<(String, f32)>)> = Vec::new();
    // The master rack is a second chain, not a track insert: its names and
    // knobs are kept apart from the strip's and ordered by the house contract.
    let mut master_order: Vec<InsertKind> = Vec::new();
    let mut master_knobs: Vec<(InsertKind, Vec<(String, f32)>)> = Vec::new();

    // First pass: the chain order, the strip's knobs, and each insert's knobs.
    for (key, value) in fields {
        match key.as_str() {
            "channel" => {
                let index = number(&key, &value)?;
                if index.fract() != 0.0 || !(0.0..=1.0).contains(&index) {
                    return Err(
                        "\"channel\" must be 0 (left/mic) or 1 (right/instrument)".to_string()
                    );
                }
                input = index as usize;
            }
            "gain" => gain = Channel::clamp_gain(number(&key, &value)? as f32),
            "pan" => pan = Channel::clamp_pan(number(&key, &value)? as f32),
            "name" => match value {
                Json::Str(text) => name = Some(text),
                _ => return Err("\"name\" must be a string".to_string()),
            },
            "master" => match value {
                Json::Array(items) => {
                    for item in items {
                        let word = match item {
                            Json::Str(word) => word,
                            _ => {
                                return Err(
                                    "\"master\" must hold master insert names".to_string()
                                )
                            }
                        };
                        let kind = master_kind(&word)?;
                        if !master_order.contains(&kind) {
                            master_order.push(kind);
                        }
                    }
                }
                Json::Object(object) => {
                    for (word, values) in object {
                        let kind = master_kind(&word)?;
                        if !master_order.contains(&kind) {
                            master_order.push(kind);
                        }
                        master_knobs.push((kind, knob_object(kind, values)?));
                    }
                }
                Json::Null => {}
                _ => {
                    return Err(
                        "\"master\" must be an array of names or an object of them".to_string()
                    )
                }
            },
            "inserts" => match value {
                Json::Array(items) => {
                    for item in items {
                        let word = match item {
                            Json::Str(word) => word,
                            _ => return Err("\"inserts\" must hold insert names".to_string()),
                        };
                        let kind = InsertKind::parse(&word)
                            .ok_or_else(|| format!("no such insert: {word}"))?;
                        order.push(kind.name().to_string());
                    }
                }
                _ => return Err("\"inserts\" must be an array of insert names".to_string()),
            },
            // A bare `master_comp` key is the rack's insert, not a track pedal.
            _ if key.starts_with("master_") => {
                let kind = master_kind(&key)?;
                if !master_order.contains(&kind) {
                    master_order.push(kind);
                }
                master_knobs.push((kind, knob_object(kind, value)?));
            }
            _ => {
                let kind = InsertKind::parse(&key)
                    .ok_or_else(|| format!("no such insert: {key}"))?;
                let values = knob_object(kind, value)?;
                if !order.iter().any(|name| name == kind.name()) {
                    order.push(kind.name().to_string());
                }
                knobs.push((kind.name().to_string(), values));
            }
        }
    }

    let mut inserts = Vec::with_capacity(order.len());
    for name in order {
        let kind = InsertKind::parse(&name).expect("a chain name came from InsertKind");
        let mut insert = PlanInsert::new(kind);
        if let Some((_, values)) = knobs.iter().find(|(key, _)| *key == name) {
            insert.knobs = values.clone();
        }
        inserts.push(insert);
    }
    // The rack is the house's fixed chain whatever order the plan named; a slot
    // the plan left out is simply not in it (mixer::MASTER_ORDER).
    master_order.sort_by_key(|kind| master_rank(*kind));
    let mut master = Vec::with_capacity(master_order.len());
    for kind in master_order {
        let mut insert = PlanInsert::new(kind);
        if let Some((_, values)) = master_knobs.iter().find(|(slot, _)| *slot == kind) {
            insert.knobs = values.clone();
        }
        master.push(insert);
    }
    Ok(ChannelPlan {
        input,
        gain,
        pan,
        inserts,
        master,
        name,
    })
}

/// One master insert name, refused when the effect is not one of the rack's
/// five. A track pedal in `master` would sit in the chain but answer no knob, so
/// it is named back to the caller instead of silently ignored.
fn master_kind(word: &str) -> Result<InsertKind, String> {
    let kind = InsertKind::parse(word).ok_or_else(|| format!("no such insert: {word}"))?;
    if kind.master_prefix().is_some() {
        return Ok(kind);
    }
    let rack = crate::mixer::MASTER_ORDER
        .iter()
        .filter_map(|kind| kind.master_prefix())
        .collect::<Vec<&str>>()
        .join(", ");
    Err(format!(
        "{word} is not a master insert (the rack holds: {rack})"
    ))
}

fn master_rank(kind: InsertKind) -> usize {
    crate::mixer::MASTER_ORDER
        .iter()
        .position(|slot| *slot == kind)
        .unwrap_or(usize::MAX)
}

/// One insert object's knobs, validated against the effect's own control list.
fn knob_object(kind: InsertKind, value: Json) -> Result<Vec<(String, f32)>, String> {
    let fields = match value {
        Json::Object(fields) => fields,
        Json::Null => return Ok(Vec::new()),
        _ => {
            return Err(format!(
                "\"{}\" must be an object of its knobs",
                kind.name()
            ))
        }
    };
    let mut knobs = Vec::with_capacity(fields.len());
    for (key, value) in fields {
        let index = kind.control_index(&key).ok_or_else(|| {
            format!(
                "{} has no \"{}\" knob (it has: {})",
                kind.name(),
                key,
                kind.controls().join(", ")
            )
        })?;
        let control = kind.controls()[index as usize];
        knobs.push((control.to_string(), kind.native_value(control, number(&key, &value)? as f32)));
    }
    Ok(knobs)
}

fn number(key: &str, value: &Json) -> Result<f64, String> {
    match value {
        Json::Num(value) if value.is_finite() => Ok(*value),
        _ => Err(format!("\"{key}\" must be a finite number")),
    }
}

// --- the JSON this module reads ---------------------------------------------

/// The plan's small JSON grammar. Objects keep key order, because the chain
/// order is the order the plan names its inserts in.
#[derive(Debug, Clone, PartialEq)]
enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

/// Nesting cap: a plan is one object of scalars and one object per insert, so
/// sixteen levels is generous and still bounds a hostile input.
const MAX_DEPTH: usize = 16;

struct Parser<'a> {
    text: &'a [u8],
    at: usize,
    depth: usize,
}

impl<'a> Parser<'a> {
    fn new(text: &'a str) -> Self {
        Parser {
            text: text.as_bytes(),
            at: 0,
            depth: 0,
        }
    }

    fn parse_value(mut self) -> Result<Json, String> {
        let value = self.value()?;
        self.skip_ws();
        if self.at != self.text.len() {
            return Err(format!("unexpected text at byte {}", self.at));
        }
        Ok(value)
    }

    fn peek(&self) -> Option<u8> {
        self.text.get(self.at).copied()
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\r' | b'\n')) {
            self.at += 1;
        }
    }

    fn bump_if(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.at += 1;
            return true;
        }
        false
    }

    fn expect(&mut self, byte: u8) -> Result<(), String> {
        if self.bump_if(byte) {
            Ok(())
        } else {
            Err(format!(
                "expected `{}` at byte {}",
                byte as char, self.at
            ))
        }
    }

    fn value(&mut self) -> Result<Json, String> {
        self.skip_ws();
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => self.string().map(Json::Str),
            Some(b't') => self.literal("true", Json::Bool(true)),
            Some(b'f') => self.literal("false", Json::Bool(false)),
            Some(b'n') => self.literal("null", Json::Null),
            Some(byte) if byte == b'-' || byte.is_ascii_digit() => self.number(),
            Some(byte) => Err(format!("unexpected `{}` at byte {}", byte as char, self.at)),
            None => Err("unexpected end of plan".to_string()),
        }
    }

    fn literal(&mut self, word: &str, value: Json) -> Result<Json, String> {
        if self.text[self.at..].starts_with(word.as_bytes()) {
            self.at += word.len();
            Ok(value)
        } else {
            Err(format!("expected `{word}` at byte {}", self.at))
        }
    }

    fn object(&mut self) -> Result<Json, String> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err("the plan nests too deeply".to_string());
        }
        self.expect(b'{')?;
        let mut fields = Vec::new();
        self.skip_ws();
        if self.bump_if(b'}') {
            self.depth -= 1;
            return Ok(Json::Object(fields));
        }
        loop {
            self.skip_ws();
            let key = self.string()?;
            self.skip_ws();
            self.expect(b':')?;
            let value = self.value()?;
            fields.push((key, value));
            self.skip_ws();
            if self.bump_if(b'}') {
                break;
            }
            self.expect(b',')?;
        }
        self.depth -= 1;
        Ok(Json::Object(fields))
    }

    fn array(&mut self) -> Result<Json, String> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err("the plan nests too deeply".to_string());
        }
        self.expect(b'[')?;
        let mut items = Vec::new();
        self.skip_ws();
        if self.bump_if(b']') {
            self.depth -= 1;
            return Ok(Json::Array(items));
        }
        loop {
            items.push(self.value()?);
            self.skip_ws();
            if self.bump_if(b']') {
                break;
            }
            self.expect(b',')?;
        }
        self.depth -= 1;
        Ok(Json::Array(items))
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        // Collect bytes, not chars: a label may be any UTF-8, and `text` is the
        // plan's original bytes, so multi-byte characters pass through intact.
        let mut out = Vec::new();
        loop {
            let byte = self
                .peek()
                .ok_or_else(|| "unterminated string in the plan".to_string())?;
            self.at += 1;
            match byte {
                b'"' => {
                    return String::from_utf8(out)
                        .map_err(|_| "a plan string was not UTF-8".to_string())
                }
                b'\\' => {
                    let escape = self
                        .peek()
                        .ok_or_else(|| "unterminated escape in the plan".to_string())?;
                    self.at += 1;
                    let character = match escape {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{0008}',
                        b'f' => '\u{000c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => self.unicode_escape()?,
                        other => {
                            return Err(format!(
                                "bad escape `\\{}` at byte {}",
                                other as char, self.at
                            ))
                        }
                    };
                    let mut encoded = [0u8; 4];
                    out.extend_from_slice(character.encode_utf8(&mut encoded).as_bytes());
                }
                other => out.push(other),
            }
        }
    }

    fn unicode_escape(&mut self) -> Result<char, String> {
        let mut value = 0u32;
        for _ in 0..4 {
            let byte = self
                .peek()
                .ok_or_else(|| "short \\u escape in the plan".to_string())?;
            self.at += 1;
            let digit = match byte {
                b'0'..=b'9' => (byte - b'0') as u32,
                b'a'..=b'f' => (byte - b'a' + 10) as u32,
                b'A'..=b'F' => (byte - b'A' + 10) as u32,
                _ => return Err(format!("bad \\u escape at byte {}", self.at)),
            };
            value = value * 16 + digit;
        }
        char::from_u32(value).ok_or_else(|| "bad \\u escape in the plan".to_string())
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.at;
        if self.bump_if(b'-') {}
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.at += 1;
        }
        if self.bump_if(b'.') {
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.at += 1;
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.at += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.at += 1;
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.at += 1;
            }
        }
        let word = std::str::from_utf8(&self.text[start..self.at])
            .map_err(|_| "a plan number was not UTF-8".to_string())?;
        word.parse::<f64>()
            .map(Json::Num)
            .map_err(|_| format!("bad number `{word}` in the plan"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_plan_is_the_raw_path() {
        assert_eq!(parse_plan(None), Ok(None));
        assert_eq!(parse_plan(Some("")), Ok(None));
        assert_eq!(parse_plan(Some("   \n\t")), Ok(None));
        assert_eq!(parse_plan(Some("null")), Ok(None));
    }

    #[test]
    fn the_fixture_string_names_one_tone_then_one_delay() {
        let plan = parse_plan(Some(FIXTURE_PLAN))
            .expect("the fixture is valid")
            .expect("the fixture is not the raw path");
        assert_eq!(plan.gain, 1.0);
        assert_eq!(plan.pan, 0.0);
        assert_eq!(plan.label(), "tone+delay");
        assert_eq!(plan.inserts.len(), 2);
        assert_eq!(plan.inserts[0].kind, InsertKind::Tone);
        assert_eq!(plan.inserts[1].kind, InsertKind::Delay);
        let delay = &plan.inserts[1].knobs;
        assert!(delay.contains(&("time".to_string(), 0.20)));
        assert!(delay.contains(&("feedback".to_string(), 0.25)));
        assert!(delay.contains(&("vol".to_string(), 0.45)));
        // Building the channel is what both sides of the gate run.
        let channel = plan.channel();
        assert_eq!(channel.gain(), 1.0);
        assert_eq!(channel.insert_names(), "tone,delay");
    }

    #[test]
    fn an_explicit_chain_order_is_kept_and_objects_supply_knobs() {
        let plan = parse_plan(Some(
            r#"{"inserts":["delay","tone"],"delay":{"time":0.05},"tone":{"treble":6}}"#,
        ))
        .expect("valid")
        .expect("not raw");
        assert_eq!(plan.label(), "delay+tone");
        assert_eq!(plan.inserts[0].kind, InsertKind::Delay);
        assert_eq!(plan.inserts[0].knobs, vec![("time".to_string(), 0.05)]);
        assert_eq!(plan.inserts[1].kind, InsertKind::Tone);
        assert_eq!(plan.inserts[1].knobs, vec![("treble".to_string(), 6.0)]);
    }

    #[test]
    fn a_named_plan_reports_its_own_label() {
        let plan = parse_plan(Some(r#"{"name":"gate-3","gain":2.0,"tone":{}}"#))
            .expect("valid")
            .expect("not raw");
        assert_eq!(plan.label(), "gate-3");
        assert_eq!(plan.gain, 2.0);
    }

    #[test]
    fn the_strip_knobs_are_clamped_like_the_channel() {
        let plan = parse_plan(Some(r#"{"gain":99,"pan":-9,"tone":{}}"#))
            .expect("valid")
            .expect("not raw");
        assert_eq!(plan.gain, Channel::MAX_GAIN);
        assert_eq!(plan.pan, -1.0);
    }

    #[test]
    fn a_typo_in_an_insert_or_knob_is_a_sentence() {
        let error = parse_plan(Some(r#"{"tone":{"base":3}}"#)).unwrap_err();
        assert!(error.contains("tone has no \"base\""), "{error}");
        assert!(error.contains("bass, mid, treble, gain"), "{error}");

        let error = parse_plan(Some(r#"{"tone":{"bass":"loud"}}"#)).unwrap_err();
        assert!(error.contains("must be a finite number"), "{error}");

        let error = parse_plan(Some(r#"{"phasor":{}}"#)).unwrap_err();
        assert!(error.contains("no such insert: phasor"), "{error}");
    }

    #[test]
    fn a_malformed_plan_is_refused_instead_of_half_armed() {
        assert!(parse_plan(Some("{")).is_err());
        assert!(parse_plan(Some("[]")).unwrap_err().contains("object"));
        assert!(parse_plan(Some(r#"{"tone":1}"#))
            .unwrap_err()
            .contains("object of its knobs"));
    }

    #[test]
    fn s16_round_trips_through_the_strip_conversion() {
        for sample in [i16::MIN, -32767, -1, 0, 1, 12345, i16::MAX] {
            let value = f32::from(sample) / 32768.0;
            assert_eq!(to_s16(value), sample, "{sample} did not round trip");
        }
    }

    #[test]
    fn the_raw_strip_writes_the_left_sample_unchanged() {
        let mut strip = Strip::new(None, 48_000, 8);
        assert!(!strip.is_stripped(), "no plan builds no channel");
        let stereo = [0.5f32, 0.5, -0.25, -0.25, 0.0, 0.0];
        let mut mono = [0i16; 8];
        strip.process(&stereo, &mut mono, 3);
        assert_eq!(&mono[..3], &[16_384, -8_192, 0]);
    }

    #[test]
    fn the_fixture_strip_runs_the_channel_after_capture() {
        // The callback's stereo ring carries duplicated mono; the strip reads
        // the plan's channel, runs the tone+delay fixture, and writes mono. The
        // echo is at 200 ms, so a burst in the first blocks comes back 9,600
        // frames later (the DSP's own assertion lives in effect.rs).
        let plan = parse_plan(Some(FIXTURE_PLAN))
            .expect("valid")
            .expect("not raw");
        let mut strip = Strip::new(Some(plan), 48_000, 512);
        assert!(strip.is_stripped());
        let frames = 12_000usize;
        let mut written = vec![0i16; frames];
        for block in 0..(frames / 512) {
            let mut stereo = vec![0.0f32; 512 * 2];
            for index in 0..512 {
                let at = block * 512 + index;
                if at < 480 {
                    let value =
                        0.5 * (std::f32::consts::TAU * 1_000.0 * at as f32 / 48_000.0).sin();
                    stereo[index * 2] = value;
                    stereo[index * 2 + 1] = value;
                }
            }
            strip.process(&stereo, &mut written[block * 512..], 512);
        }
        let dry: i64 = written[..480].iter().map(|s| i64::from(*s).abs()).sum();
        let echo: i64 = written[9_600..10_080].iter().map(|s| i64::from(*s).abs()).sum();
        let gap: i64 = written[4_800..5_280].iter().map(|s| i64::from(*s).abs()).sum();
        assert!(dry > 0, "the burst was not written");
        assert!(echo > dry / 4, "the repeat was not written: dry {dry}, echo {echo}");
        assert!(gap < echo / 4, "the delay echoed before its time: gap {gap}, echo {echo}");
    }

    #[test]
    fn a_plan_names_the_input_channel_and_the_strip_reads_it() {
        let plan = parse_plan(Some(r#"{"channel":1}"#))
            .expect("valid")
            .expect("not raw");
        assert_eq!(plan.input, 1);
        let mut strip = Strip::new(Some(plan), 48_000, 8);
        // Left is the mic, right is the instrument: the strip must take right.
        let stereo = [0.5f32, -0.25, 0.5, -0.25];
        let mut mono = [0i16; 8];
        strip.process(&stereo, &mut mono, 2);
        assert_eq!(&mono[..2], &[-8_192, -8_192]);
    }

    #[test]
    fn a_channel_outside_the_stereo_capture_is_refused() {
        assert!(parse_plan(Some(r#"{"channel":2}"#))
            .unwrap_err()
            .contains("0 (left/mic) or 1"));
        assert!(parse_plan(Some(r#"{"channel":0.5}"#)).is_err());
    }

    #[test]
    fn the_master_rack_is_the_house_order_whatever_the_plan_named() {
        let plan = parse_plan(Some(r#"{"master":["master_limiter","master_comp"]}"#))
            .expect("valid")
            .expect("not raw");
        assert!(plan.inserts.is_empty(), "a master insert is not a track pedal");
        assert_eq!(plan.master.len(), 2);
        assert_eq!(plan.master[0].kind, InsertKind::Compressor);
        assert_eq!(plan.master[1].kind, InsertKind::Limiter);
        assert_eq!(plan.master_label(), "master_comp+master_limiter");
    }

    #[test]
    fn master_knobs_ride_the_rack_and_a_track_pedal_is_refused() {
        let plan = parse_plan(Some(r#"{"master_comp":{"thresh":-20}}"#))
            .expect("valid")
            .expect("not raw");
        assert_eq!(plan.master[0].kind, InsertKind::Compressor);
        assert_eq!(plan.master[0].knobs, vec![("thresh".to_string(), -20.0)]);

        let error = parse_plan(Some(r#"{"master":["tone"]}"#)).unwrap_err();
        assert!(error.contains("tone is not a master insert"), "{error}");
        assert!(error.contains("master_comp"), "{error}");
    }
}
