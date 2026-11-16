// SPDX-License-Identifier: AGPL-3.0-only
//! The public header must declare exactly the functions this crate exports.
//!
//! Every `extern "C" fn oscillux_*` definition under `src/` is compared with every
//! `oscillux_*(...)` prototype in `ffi/include/oscillux.h` by name and exact types.
//! Exports added in any module are picked up without editing this test. Every prototype must
//! carry the `OSCILLUX_API` export/import macro.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

/// Parameter types in order, followed by return type.
type Signature = (Vec<String>, String);

const PREFIX: &str = "oscillux_";
const EXPORT_MACRO: &str = "OSCILLUX_API";

fn rust_sources(dir: &Path) -> Vec<PathBuf> {
    let entries = fs::read_dir(dir).expect("read src dir");
    let paths: Vec<PathBuf> = entries.map(|e| e.expect("dir entry").path()).collect();
    let nested = paths
        .iter()
        .filter(|p| p.is_dir())
        .flat_map(|p| rust_sources(p));
    let files = paths
        .iter()
        .filter(|p| p.extension().is_some_and(|e| e == "rs"))
        .cloned();
    files.chain(nested).collect()
}

/// Text between the parenthesis at `open` and its match.
fn parenthesised(text: &str, open: usize) -> &str {
    let mut depth = 0;
    for (i, c) in text[open..].char_indices() {
        depth += match c {
            '(' => 1,
            ')' => -1,
            _ => 0,
        };
        if depth == 0 {
            return &text[open + 1..open + i];
        }
    }
    panic!("unbalanced parentheses")
}

fn rust_type(ty: &str) -> String {
    let ty = ty.trim();
    if let Some(inner) = ty.strip_prefix("*mut ") {
        return format!("{}*", rust_type(inner));
    }
    if let Some(inner) = ty.strip_prefix("*const ") {
        let inner = rust_type(inner);
        return if inner.contains('*') {
            format!("{inner}const*")
        } else {
            format!("const{inner}*")
        };
    }
    match ty {
        "()" => "void",
        "u8" => "uint8_t",
        "u32" => "uint32_t",
        "i32" => "int32_t",
        "u64" => "uint64_t",
        "usize" => "size_t",
        "f32" => "float",
        "f64" => "double",
        "c_char" | "core::ffi::c_char" | "std::ffi::c_char" => "char",
        "DspConfig" => "OscilluxDspConfig",
        "DspFrame" => "OscilluxDspFrame",
        "Onset" => "OscilluxDspOnset",
        name if name.starts_with("Oscillux") && name.chars().all(|c| c.is_ascii_alphanumeric()) => {
            name
        }
        _ => panic!("unsupported ABI type: {ty}; add an explicit mapping"),
    }
    .to_string()
}

fn c_type(ty: &str) -> String {
    ty.chars().filter(|c| !c.is_whitespace()).collect()
}

fn c_parameter_type(param: &str) -> String {
    let param = param.trim();
    let name_start = param
        .rfind(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .expect("named C parameter")
        + 1;
    c_type(&param[..name_start])
}

fn ident_at(text: &str, start: usize) -> &str {
    let len = text[start..]
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .unwrap_or(text.len() - start);
    &text[start..start + len]
}

fn rust_exports() -> BTreeMap<String, Signature> {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let marker = "extern \"C\" fn ";
    let mut exports = BTreeMap::new();
    for file in rust_sources(&src) {
        let text = strip_comments(&fs::read_to_string(&file).expect("read source"));
        for (at, _) in text.match_indices(marker) {
            let declaration_line = text[..at].rfind('\n').unwrap_or(0);
            let attributes = text[..declaration_line].trim_end();
            assert!(
                attributes.ends_with("#[no_mangle]")
                    || attributes.ends_with("#[unsafe(no_mangle)]"),
                "C export must retain its symbol name: {}",
                file.display()
            );
            let start = at + marker.len();
            let name = ident_at(&text, start);
            if !name.starts_with(PREFIX) {
                continue;
            }
            let open = start + name.len();
            let params = parenthesised(&text, open);
            let after = text[open + params.len() + 2..].trim_start();
            let params = params
                .split(',')
                .filter(|p| !p.trim().is_empty())
                .map(|p| rust_type(p.split_once(':').expect("typed parameter").1))
                .collect();
            let ret = after.split('{').next().expect("function body").trim();
            let signature = (params, rust_type(ret.strip_prefix("->").unwrap_or("()")));
            assert!(
                exports.insert(name.to_string(), signature).is_none(),
                "{name} exported twice"
            );
        }
    }
    exports
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

fn header_prototypes(header: &str) -> BTreeMap<String, Signature> {
    let code = strip_comments(header)
        .lines()
        .filter(|l| !l.trim_start().starts_with('#'))
        .collect::<Vec<_>>()
        .join("\n");
    let mut prototypes = BTreeMap::new();
    for statement in code.split(';') {
        let Some(at) = statement.find(PREFIX) else {
            continue;
        };
        let name = ident_at(statement, at);
        let open = at + name.len();
        if !statement[open..].starts_with('(') {
            continue;
        }
        let ret = statement[..at]
            .rsplit(['{', '}'])
            .next()
            .expect("return type")
            .trim()
            .strip_prefix(EXPORT_MACRO)
            .unwrap_or_else(|| panic!("{name} must be declared with {EXPORT_MACRO}"));
        let params = parenthesised(statement, open)
            .split(',')
            .filter(|p| !p.trim().is_empty() && p.trim() != "void")
            .map(c_parameter_type)
            .collect();
        let signature = (params, c_type(ret));
        assert!(
            prototypes.insert(name.to_string(), signature).is_none(),
            "{name} declared twice"
        );
    }
    prototypes
}

#[test]
fn header_declares_exactly_the_exported_functions() {
    let exports = rust_exports();
    let prototypes = header_prototypes(include_str!("../../../ffi/include/oscillux.h"));
    assert!(!exports.is_empty(), "no exports found");
    let names: BTreeSet<&String> = exports.keys().chain(prototypes.keys()).collect();
    let mismatches: Vec<String> = names
        .into_iter()
        .filter(|name| exports.get(*name) != prototypes.get(*name))
        .map(|name| {
            format!(
                "{name}: exported {:?}, declared {:?}",
                exports.get(name),
                prototypes.get(name)
            )
        })
        .collect();
    assert!(
        mismatches.is_empty(),
        "(parameter types, return type):\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn same_arity_type_mutations_are_detected() {
    let header = include_str!("../../../ffi/include/oscillux.h");
    let good = header_prototypes(header);
    for changed in [
        header.replace(
            "uint32_t oscillux_abi_version",
            "uint64_t oscillux_abi_version",
        ),
        header.replace("const float *samples", "const double *samples"),
        header.replace("const float *samples", "float *samples"),
        header.replace("OscilluxDsp **out_dsp", "OscilluxDsp *out_dsp"),
        header.replace(
            "const char *oscillux_status_string",
            "char *oscillux_status_string",
        ),
        header.replace("const char **out_field", "char **out_field"),
    ] {
        assert_ne!(good, header_prototypes(&changed));
    }
}

#[test]
fn a_prototype_without_the_export_macro_is_rejected() {
    let header = include_str!("../../../ffi/include/oscillux.h");
    let changed = header.replace(
        "OSCILLUX_API void oscillux_dsp_destroy",
        "void oscillux_dsp_destroy",
    );
    assert_ne!(header, changed);
    assert!(std::panic::catch_unwind(|| header_prototypes(&changed)).is_err());
}
