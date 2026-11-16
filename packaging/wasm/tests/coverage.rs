// SPDX-License-Identifier: AGPL-3.0-only
//! Every `OSCILLUX_API` export in oscillux.h has a wasm binding, a JNI binding, or an
//! exclusion with a reason in the docs/packaging.md binding-coverage table.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

fn read(path: &str) -> String {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    fs::read_to_string(root.join(path)).unwrap_or_else(|e| panic!("{path}: {e}"))
}

/// C-family source with comments replaced by spaces and string/char literal contents blanked,
/// keeping newlines and byte offsets, so names and braces are only matched in code.
fn code_only(source: &str) -> String {
    let bytes = source.as_bytes();
    let mut out = bytes.to_vec();
    let blank = |out: &mut Vec<u8>, from: usize, to: usize| {
        for b in &mut out[from..to] {
            if *b != b'\n' {
                *b = b' ';
            }
        }
    };
    let mut i = 0;
    while i < bytes.len() {
        match (bytes[i], bytes.get(i + 1).copied()) {
            (b'/', Some(b'/')) => {
                let end = source[i..].find('\n').map_or(bytes.len(), |n| i + n);
                blank(&mut out, i, end);
                i = end;
            }
            (b'/', Some(b'*')) => {
                let end = source[i + 2..]
                    .find("*/")
                    .map_or(bytes.len(), |n| i + 2 + n + 2);
                blank(&mut out, i, end);
                i = end;
            }
            (b'"', _) => {
                let mut j = i + 1;
                while j < bytes.len() && bytes[j] != b'"' {
                    j += if bytes[j] == b'\\' { 2 } else { 1 };
                }
                blank(&mut out, i + 1, j.min(bytes.len()));
                i = j + 1;
            }
            // A one-character literal such as '{' or '\n'; a Rust lifetime has no closing quote.
            (b'\'', Some(c)) => {
                let len = if c == b'\\' { 4 } else { 3 };
                if bytes.get(i + len - 1) == Some(&b'\'') {
                    blank(&mut out, i + 1, i + len - 1);
                    i += len;
                } else {
                    i += 1;
                }
            }
            _ => i += 1,
        }
    }
    String::from_utf8(out).expect("blanking keeps UTF-8")
}

/// Bodies (between the braces) of every block whose header starts with `opener`, in
/// comment-free source.
fn blocks<'a>(code: &'a str, opener: &str) -> Vec<&'a str> {
    let mut found = Vec::new();
    let mut from = 0;
    while let Some(at) = code[from..].find(opener) {
        let start = from + at;
        from = start + opener.len();
        let boundary = start == 0 || !is_ident(code.as_bytes()[start - 1] as char);
        if !boundary {
            continue;
        }
        let open = start + code[start..].find('{').expect("block opens");
        let mut depth = 0;
        for (n, c) in code[open..].char_indices() {
            match c {
                '{' => depth += 1,
                '}' => depth -= 1,
                _ => {}
            }
            if depth == 0 {
                found.push(&code[open + 1..open + n]);
                break;
            }
        }
    }
    found
}

fn is_ident(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '$'
}

/// Whole-identifier occurrences of `word`.
fn words<'a>(code: &'a str, word: &'a str) -> impl Iterator<Item = usize> + 'a {
    code.match_indices(word)
        .map(|(at, _)| at)
        .filter(move |&at| {
            let before = code[..at].chars().next_back();
            let after = code[at + word.len()..].chars().next();
            !before.is_some_and(is_ident) && !after.is_some_and(is_ident)
        })
}

/// Names of the exported prototypes, which may span several lines.
fn header_exports(header: &str) -> Vec<String> {
    let mut names = Vec::new();
    let mut rest = header;
    while let Some(at) = rest.find("\nOSCILLUX_API ") {
        let declaration = &rest[at..];
        let end = declaration.find(';').expect("prototype ends with ';'");
        let prototype = &declaration[..end];
        let open = prototype.find('(').expect("prototype has parameters");
        let name = prototype[..open]
            .rsplit(|c: char| !is_ident(c))
            .next()
            .unwrap();
        assert!(name.starts_with("oscillux_"), "unexpected export {name}");
        names.push(name.to_string());
        rest = &declaration[end..];
    }
    names
}

/// `OSCILLUX_API` tokens in code that are not on a `#define` line, however they are spaced.
fn api_tokens(header: &str) -> usize {
    words(header, "OSCILLUX_API")
        .filter(|&at| {
            let line_start = header[..at].rfind('\n').map_or(0, |n| n + 1);
            let line = header[line_start..at].trim_start();
            !(line.starts_with('#') && line[1..].trim_start().starts_with("define"))
        })
        .count()
}

/// Backticked names in a table cell, or None for `excluded: <reason>`.
fn bindings(export: &str, column: &str, cell: &str) -> Option<Vec<String>> {
    if let Some(reason) = cell.strip_prefix("excluded:") {
        assert!(
            reason.trim().len() >= 20,
            "{export}: {column} exclusion needs a reason"
        );
        return None;
    }
    let names: Vec<String> = cell
        .split('`')
        .skip(1)
        .step_by(2)
        .map(str::to_string)
        .collect();
    assert!(
        !names.is_empty(),
        "{export}: no {column} binding or exclusion"
    );
    Some(names)
}

/// `name`, `new Owner` or `Owner.member` (Java owners may be nested: `Oscillux.Dsp`).
fn split(name: &str) -> (bool, Vec<&str>) {
    match name.strip_prefix("new ") {
        Some(owner) => (true, owner.split('.').collect()),
        None => (false, name.split('.').collect()),
    }
}

/// Whether a wasm-bindgen item body exports `member` under that JS name.
fn exports_member(body: &str, member: &str) -> bool {
    [
        format!("js_name = {member})"),
        format!("js_name = {member},"),
        format!("getter = {member})"),
        format!("fn {member}("),
    ]
    .iter()
    .any(|p| body.contains(p.as_str()))
}

/// `code` with every `impl` block body removed: the free functions.
fn outside_impls(code: &str) -> String {
    let mut rest = code.to_string();
    for body in blocks(code, "impl ") {
        let at = body.as_ptr() as usize - code.as_ptr() as usize;
        rest.replace_range(at..at + body.len(), &" ".repeat(body.len()));
    }
    rest
}

fn check_wasm(export: &str, name: &str, code: &str) {
    let (construct, parts) = split(name);
    let impls = |c: &str| blocks(code, &format!("impl {c} {{"));
    let found = match (construct, parts.as_slice()) {
        (true, [class]) => impls(class).iter().any(|b| b.contains("constructor")),
        (false, [function]) => exports_member(&outside_impls(code), function),
        (false, [class, "free"]) => !blocks(code, &format!("impl Drop for {class} {{")).is_empty(),
        (false, [class, member]) => impls(class).iter().any(|b| exports_member(b, member)),
        _ => false,
    };
    assert!(found, "{export}: wasm binding `{name}` not found");
}

/// Body of Java class `class` inside `scope`, followed by the bodies it inherits from.
fn java_class<'a>(scope: &'a str, class: &str) -> Vec<&'a str> {
    let opener = format!("class {class} ");
    let Some(at) = words(scope, &format!("class {class}")).next() else {
        return Vec::new();
    };
    let header = &scope[at..at + scope[at..].find('{').expect("class body")];
    let mut found: Vec<&str> = blocks(&scope[at..], &opener).into_iter().take(1).collect();
    if let Some(parent) = header
        .split_whitespace()
        .skip_while(|w| *w != "extends")
        .nth(1)
    {
        found.extend(java_class(scope, parent));
    }
    found
}

fn check_java(export: &str, name: &str, java: &str) {
    let (construct, parts) = split(name);
    assert_eq!(
        parts[0], "Oscillux",
        "{export}: `{name}` is not on Oscillux"
    );
    let root = java_class(java, "Oscillux");
    let root = root.first().expect("class Oscillux");
    let found = match (construct, &parts[1..]) {
        (true, [class]) => java_class(root, class)
            .first()
            .is_some_and(|b| b.contains(&format!("public {class}("))),
        (false, [method]) => root
            .lines()
            .any(|l| l.contains("public static") && l.contains(&format!(" {method}("))),
        (false, [class, method]) => java_class(root, class).iter().any(|b| {
            b.lines()
                .any(|l| l.contains("public ") && l.contains(&format!(" {method}(")))
        }),
        _ => false,
    };
    assert!(found, "{export}: Java binding `{name}` not found");
}

/// Names before `(` of the `native` method declarations.
fn java_natives(java: &str) -> BTreeSet<String> {
    java.lines()
        .filter(|l| l.split_whitespace().any(|w| w == "native"))
        .map(|l| {
            let open = l.find('(').expect("native has parameters");
            l[..open].rsplit(' ').next().unwrap().to_string()
        })
        .collect()
}

/// Method names the C file defines through `JNI(name)`, directly or via the `SIZE` macro.
fn jni_symbols(jni: &str) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    for line in jni
        .lines()
        .filter(|l| !l.trim_start().starts_with("#define"))
    {
        for marker in ["JNI(", "SIZE("] {
            for (at, _) in line.match_indices(marker) {
                if at > 0 && is_ident(line.as_bytes()[at - 1] as char) {
                    continue;
                }
                let rest = &line[at + marker.len()..];
                let end = rest.find(|c: char| !is_ident(c)).unwrap_or(rest.len());
                names.insert(rest[..end].to_string());
            }
        }
    }
    names
}

#[test]
fn every_header_export_is_bound_or_excluded() {
    let header = code_only(&read("ffi/include/oscillux.h"));
    let exports = header_exports(&header);
    assert!(exports.len() >= 30, "parsed only {} exports", exports.len());
    assert_eq!(
        api_tokens(&header),
        exports.len(),
        "OSCILLUX_API declarations the export parser did not read"
    );
    let docs = read("docs/packaging.md");
    let table = docs
        .split("<!-- binding-coverage:start -->")
        .nth(1)
        .and_then(|t| t.split("<!-- binding-coverage:end -->").next())
        .expect("docs/packaging.md binding-coverage table");
    let wasm = code_only(&read("packaging/wasm/src/lib.rs"));
    let java = code_only(&read("packaging/android/Oscillux.java"));
    let jni = code_only(&read("packaging/android/oscillux_jni.c"));

    let natives = java_natives(&java);
    let symbols = jni_symbols(&jni);
    assert!(natives.len() >= 30, "parsed only {} natives", natives.len());
    assert_eq!(
        natives.difference(&symbols).collect::<Vec<_>>(),
        Vec::<&String>::new(),
        "Java natives without a JNI(...) definition"
    );
    assert_eq!(
        symbols.difference(&natives).collect::<Vec<_>>(),
        Vec::<&String>::new(),
        "JNI(...) definitions without a Java native"
    );

    let mut documented = BTreeSet::new();
    for row in table.lines().filter(|l| l.starts_with("| `oscillux_")) {
        let cells: Vec<&str> = row.split('|').map(str::trim).collect();
        assert_eq!(cells.len(), 5, "malformed row: {row}");
        let export = cells[1].trim_matches('`');
        assert!(
            documented.insert(export.to_string()),
            "{export}: duplicate row"
        );
        if let Some(names) = bindings(export, "wasm", cells[2]) {
            assert!(
                words(&wasm, export).any(|at| wasm[at + export.len()..].starts_with('(')),
                "{export}: not called from lib.rs"
            );
            for name in &names {
                check_wasm(export, name, &wasm);
            }
        }
        if let Some(names) = bindings(export, "JNI", cells[3]) {
            assert!(
                words(&jni, export).any(|at| jni[at + export.len()..].starts_with('(')),
                "{export}: not called from oscillux_jni.c"
            );
            for name in &names {
                check_java(export, name, &java);
            }
        }
    }
    let header: BTreeSet<String> = exports.into_iter().collect();
    let missing: Vec<_> = header.difference(&documented).collect();
    let stale: Vec<_> = documented.difference(&header).collect();
    assert!(
        missing.is_empty(),
        "exports without a coverage row: {missing:?}"
    );
    assert!(
        stale.is_empty(),
        "coverage rows for removed exports: {stale:?}"
    );
}

#[test]
fn header_parser_counts_every_declaration() {
    let header = code_only(
        "#define OSCILLUX_API\n/* OSCILLUX_API in a comment */\n\
         OSCILLUX_API int oscillux_a(void);\n\
         OSCILLUX_API\nint oscillux_b(void);\n\
         int x; OSCILLUX_API int oscillux_c(void);\n",
    );
    assert_eq!(header_exports(&header), ["oscillux_a"]);
    assert_eq!(api_tokens(&header), 3);
}
