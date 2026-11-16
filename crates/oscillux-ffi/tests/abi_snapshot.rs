// SPDX-License-Identifier: AGPL-3.0-only
//! The C interface must match the committed snapshot `ffi/abi-snapshot.txt`: every value
//! constant, function prototype and opaque handle in `ffi/include/oscillux.h`, and every struct's
//! size, alignment and member offsets, sizes and types as the host C compiler lays them out. Any
//! difference fails with a line diff until `make abi-snapshot` rewrites the snapshot, so an
//! interface change cannot land without a reviewed snapshot change. The release version defines
//! are left out because they change with every release; `header_constants.rs` ties them to Cargo.
//!
//! Layouts are those of a 64-bit host, on which macOS and Linux agree; 32-bit targets differ in
//! `size_t` members. This file also enforces the header's extensible-struct rule: a
//! configuration or policy struct released after ABI version 1 begins with `struct_size`.

use std::collections::BTreeSet;
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

const HEADER: &str = include_str!("../../../ffi/include/oscillux.h");
const SNAPSHOT: &str = "ffi/abi-snapshot.txt";
const UPDATE_ENV: &str = "OSCILLUX_UPDATE_ABI_SNAPSHOT";
const EXPORT_MACRO: &str = "OSCILLUX_API ";

/// Defines that are not interface values: the include guard, the export macro and the release
/// version.
const NOT_ABI: [&str; 6] = [
    "OSCILLUX_H",
    "OSCILLUX_API",
    "OSCILLUX_VERSION",
    "OSCILLUX_VERSION_MAJOR",
    "OSCILLUX_VERSION_MINOR",
    "OSCILLUX_VERSION_PATCH",
];

/// Configuration and policy structs released in ABI version 1, before the `struct_size` rule.
/// The next ABI version adds `struct_size` to each and removes it from this list.
const BEFORE_STRUCT_SIZE: [&str; 5] = [
    "OscilluxCurveConfig",
    "OscilluxDspConfig",
    "OscilluxGovernorConfig",
    "OscilluxLimiterPolicy",
    "OscilluxMappingConfig",
];

struct Member {
    name: String,
    /// Declared type with any array dimensions appended, e.g. `uint32_t[OSCILLUX_MAPPING_GROUPS][2]`.
    ty: String,
}

struct Struct {
    name: String,
    members: Vec<Member>,
}

/// Snapshot lines that need no compiler, and the structs whose layout the compiler supplies.
struct Interface {
    lines: Vec<String>,
    structs: Vec<Struct>,
}

fn strip_comments(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(at) = rest.find("/*") {
        out.push_str(&rest[..at]);
        let end = rest[at..].find("*/").expect("unterminated comment");
        rest = &rest[at + end + 2..];
    }
    out.push_str(rest);
    let lines = out.lines().map(|l| l.split("//").next().unwrap());
    lines.collect::<Vec<_>>().join("\n")
}

fn ident(text: &str) -> &str {
    let len = text
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .unwrap_or(text.len());
    &text[..len]
}

fn words(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Splits a member declaration such as `double spectrum[OSCILLUX_DSP_MAX_BANDS]`.
fn member(declaration: &str) -> Member {
    let (base, dims) = match declaration.find('[') {
        Some(at) => declaration.split_at(at),
        None => (declaration, ""),
    };
    let base = base.trim_end();
    let split = base
        .rfind(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .unwrap_or_else(|| panic!("member without a type: {declaration}"));
    let (ty, name) = base.split_at(split + 1);
    let dims: String = dims.chars().filter(|c| !c.is_whitespace()).collect();
    Member {
        name: name.to_string(),
        ty: format!(
            "{}{dims}",
            words(&ty.replace('*', " * ")).replace(" *", "*")
        ),
    }
}

fn parse(header: &str) -> Interface {
    let stripped = strip_comments(header);
    let mut lines = Vec::new();
    for line in stripped.lines() {
        let mut tokens = line.split_whitespace();
        if tokens.next() != Some("#define") {
            continue;
        }
        let name = tokens.next().expect("define name");
        if name.starts_with("OSCILLUX_") && !NOT_ABI.contains(&name) {
            lines.push(format!(
                "define {name} {}",
                tokens.collect::<Vec<_>>().join(" ")
            ));
        }
    }
    let code = stripped
        .lines()
        .filter(|l| !l.trim_start().starts_with('#'))
        .collect::<Vec<_>>()
        .join("\n");
    for statement in code.split(';') {
        if let Some(at) = statement.find(EXPORT_MACRO) {
            let prototype = words(&statement[at + EXPORT_MACRO.len()..]).replace("( ", "(");
            lines.push(format!("function {prototype}"));
        }
    }
    let mut structs = Vec::new();
    let mut rest = code.as_str();
    while let Some(at) = rest.find("typedef struct ") {
        let after = &rest[at + "typedef struct ".len()..];
        let name = ident(after).to_string();
        let tail = after[name.len()..].trim_start();
        match tail.strip_prefix('{') {
            Some(body) => {
                let end = body.find('}').expect("struct body");
                let members = body[..end]
                    .split(';')
                    .map(str::trim)
                    .filter(|d| !d.is_empty())
                    .map(member)
                    .collect();
                structs.push(Struct { name, members });
                rest = &body[end..];
            }
            None => {
                lines.push(format!("opaque {name}"));
                rest = tail;
            }
        }
    }
    Interface { lines, structs }
}

struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Compiles and runs a program that prints each struct's layout as the host compiler sees it.
fn layout_lines(header: &str, structs: &[Struct]) -> Vec<String> {
    static RUN: AtomicUsize = AtomicUsize::new(0);
    let run = RUN.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("oscillux-abi-{}-{run}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let scratch = Scratch(dir);
    let mut program = format!("#include <stdio.h>\n{header}\nint main(void) {{\n");
    for s in structs {
        let name = &s.name;
        writeln!(
            program,
            "printf(\"struct {name} size %zu align %zu\\n\", sizeof({name}), (size_t)_Alignof({name}));"
        )
        .unwrap();
        for m in &s.members {
            let (field, ty) = (&m.name, &m.ty);
            writeln!(
                program,
                "printf(\"member {name}.{field} offset %zu size %zu type {ty}\\n\", \
                 offsetof({name}, {field}), sizeof((({name} *)0)->{field}));"
            )
            .unwrap();
        }
    }
    program.push_str("return 0;\n}\n");
    let source = scratch.0.join("abi.c");
    let binary = scratch.0.join("abi");
    std::fs::write(&source, program).unwrap();
    let compiled = Command::new("cc")
        .args(["-std=c11", "-Werror", "-o"])
        .arg(&binary)
        .arg(&source)
        .output()
        .expect("C compiler required for the ABI snapshot");
    assert!(
        compiled.status.success(),
        "layout program failed to compile:\n{}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    let ran = Command::new(&binary).output().expect("run layout program");
    assert!(ran.status.success(), "layout program failed");
    let stdout = String::from_utf8(ran.stdout).expect("ASCII layout output");
    stdout.lines().map(str::to_string).collect()
}

/// A line's kind and the name it declares, so that functions sort by name.
fn subject(line: &str) -> (&str, &str) {
    let (kind, rest) = line.split_once(' ').expect("kind");
    let name = match (kind, rest.find('(')) {
        ("function", Some(open)) => rest[..open].rsplit([' ', '*']).next().unwrap(),
        _ => rest.split(' ').next().unwrap(),
    };
    (kind, name)
}

/// The snapshot text of `header`: sorted constants, functions and handles, then structs sorted
/// by name with members in declaration order.
fn snapshot(header: &str) -> String {
    let mut interface = parse(header);
    interface.lines.sort_by(|a, b| subject(a).cmp(&subject(b)));
    interface.structs.sort_by(|a, b| a.name.cmp(&b.name));
    let mut text = String::from(
        "# SPDX-License-Identifier: AGPL-3.0-only\n\
         # C ABI snapshot of ffi/include/oscillux.h on a 64-bit host, checked by\n\
         # crates/oscillux-ffi/tests/abi_snapshot.rs. Regenerate with `make abi-snapshot`.\n",
    );
    let layout = layout_lines(header, &interface.structs);
    for line in interface.lines.iter().chain(&layout) {
        text.push_str(line);
        text.push('\n');
    }
    text
}

/// Lines only in `committed` (-) and only in `current` (+). Every snapshot line names its own
/// subject, so the lines read on their own without context.
fn diff(committed: &str, current: &str) -> Vec<String> {
    let old: BTreeSet<&str> = committed.lines().collect();
    let new: BTreeSet<&str> = current.lines().collect();
    let removed = committed.lines().filter(|l| !new.contains(l));
    let added = current.lines().filter(|l| !old.contains(l));
    let mut lines: Vec<String> = removed.map(|l| format!("- {l}")).collect();
    lines.extend(added.map(|l| format!("+ {l}")));
    lines
}

fn snapshot_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(SNAPSHOT)
}

#[test]
fn header_matches_the_committed_abi_snapshot() {
    let current = snapshot(HEADER);
    let path = snapshot_path();
    if std::env::var_os(UPDATE_ENV).is_some() {
        std::fs::write(&path, &current).expect("write ABI snapshot");
        eprintln!("wrote {SNAPSHOT}");
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_default();
    if committed == current {
        return;
    }
    let mut lines = diff(&committed, &current);
    if lines.is_empty() {
        lines.push("(same lines in a different order)".to_string());
    }
    panic!(
        "{SNAPSHOT} differs from ffi/include/oscillux.h (- snapshot, + header):\n{}\n\n\
         If the change is intended, run `make abi-snapshot`, commit {SNAPSHOT} and add a \
         CHANGELOG.md entry. A changed signature, layout or status value, or a removed \
         function, also increments OSCILLUX_ABI_VERSION (docs/api-stability.md).",
        lines.join("\n")
    );
}

#[test]
fn the_snapshot_detects_interface_changes() {
    let good = snapshot(HEADER);
    for (mutated, expect) in [
        (
            HEADER.replace("OSCILLUX_API uint32_t oscillux_abi_version(void);", ""),
            "- function uint32_t oscillux_abi_version(void)",
        ),
        (
            HEADER.replace("#define OSCILLUX_ERR_PANIC (-3)", "#define OSCILLUX_ERR_PANIC (-4)"),
            "+ define OSCILLUX_ERR_PANIC (-4)",
        ),
        (
            HEADER.replace("double rms;", "float rms;"),
            "+ member OscilluxDspFrame.rms offset 24 size 4 type float",
        ),
        (
            HEADER.replace(
                "uint32_t strobe_banned;",
                "uint32_t strobe_banned;\n    uint32_t added;",
            ),
            "+ member OscilluxLimiterPolicy.added offset 32 size 4 type uint32_t",
        ),
        (
            HEADER.replace("uint32_t level);", "uint32_t start_level);"),
            "+ function int32_t oscillux_governor_reset(OscilluxGovernor *handle, uint32_t start_level)",
        ),
    ] {
        assert_ne!(mutated, HEADER, "mutation did not apply: {expect}");
        let lines = diff(&good, &snapshot(&mutated));
        assert!(lines.iter().any(|l| l == expect), "{expect} not in {lines:#?}");
    }
}

/// Configuration and policy structs that break the extensible-struct rule.
fn struct_size_violations(header: &str) -> Vec<String> {
    let mut violations = Vec::new();
    for s in parse(header).structs {
        let extensible = s.name.ends_with("Config") || s.name.ends_with("Policy");
        let first = s.members.first().map(|m| (m.ty.as_str(), m.name.as_str()));
        let leads = first == Some(("uint32_t", "struct_size"));
        if BEFORE_STRUCT_SIZE.contains(&s.name.as_str()) {
            if leads {
                violations.push(format!("{}: remove it from BEFORE_STRUCT_SIZE", s.name));
            }
        } else if extensible && !leads {
            violations.push(format!("{}: must begin with uint32_t struct_size", s.name));
        }
    }
    violations
}

#[test]
fn new_config_and_policy_structs_begin_with_struct_size() {
    let declared: Vec<String> = parse(HEADER).structs.into_iter().map(|s| s.name).collect();
    for name in BEFORE_STRUCT_SIZE {
        assert!(declared.iter().any(|d| d == name), "{name} not declared");
    }
    assert_eq!(struct_size_violations(HEADER), Vec::<String>::new());
    let added = HEADER.replace(
        "typedef struct OscilluxLimiter OscilluxLimiter;",
        "typedef struct OscilluxLimiter OscilluxLimiter;\n\
         typedef struct OscilluxExampleConfig { double gain; } OscilluxExampleConfig;\n\
         typedef struct OscilluxSizedConfig { uint32_t struct_size; double gain; } OscilluxSizedConfig;",
    );
    assert_eq!(
        struct_size_violations(&added),
        ["OscilluxExampleConfig: must begin with uint32_t struct_size"]
    );
}
