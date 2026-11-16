// SPDX-License-Identifier: AGPL-3.0-only
//! Runs `conformance/packing/overlay-uniforms.json` against the overlay packer and flash mask,
//! bit for bit, and checks the schema's offsets against the packed block.

mod json;

use json::Value;
use oscillux_core::overlay::{
    flash_mask, pack, OverlayConfig, OverlayError, OverlayRegion, MAX_OVERLAY_REGIONS,
    OVERLAY_UNIFORMS_SIZE,
};

fn vectors() -> Value {
    json::parse(include_str!(
        "../../../conformance/packing/overlay-uniforms.json"
    ))
    .expect("parse vector file")
}

fn config(v: &Value) -> OverlayConfig {
    OverlayConfig {
        viewport_width: v.get("viewport_width").num(),
        viewport_height: v.get("viewport_height").num(),
        contrast_ratio: v.get("contrast_ratio").num(),
        intensity: v.get("intensity").num(),
        frame_interval_ms: v.get("frame_interval_ms").num(),
        alpha: v.get("alpha").num(),
        output_levels: v.get("output_levels").num() as u32,
        reduced_motion: v.get("reduced_motion").boolean(),
        premultiplied_alpha: v.get("premultiplied_alpha").boolean(),
    }
}

fn regions(v: &Value) -> Vec<OverlayRegion> {
    v.arr()
        .iter()
        .map(|r| OverlayRegion {
            x: r.get("x").num(),
            y: r.get("y").num(),
            width: r.get("width").num(),
            height: r.get("height").num(),
            corner_radius: r.get("corner_radius").num(),
            feather: r.get("feather").num(),
            strength: r.get("strength").num(),
            mode: r.get("mode").num() as u32,
            reserved: r.get("reserved").num() as u32,
        })
        .collect()
}

fn hex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
        .collect()
}

fn error_name(e: OverlayError) -> String {
    format!("{e:?}")
}

#[test]
fn packing_matches_the_vectors_bit_for_bit() {
    let doc = vectors();
    assert_eq!(doc.get("size").num() as usize, OVERLAY_UNIFORMS_SIZE);
    let mut packed = 0;
    for case in doc.get("pack").arr() {
        let name = case.get("name").str();
        let cfg = config(case.get("config"));
        let list = regions(case.get("regions"));
        let mut out = [0xa5u8; OVERLAY_UNIFORMS_SIZE + 8];
        let result = pack(&cfg, &list, &mut out);
        match case {
            Value::Obj(fields) if fields.iter().any(|(k, _)| k == "refused") => {
                let want = case.get("refused").str();
                assert_eq!(result.map_err(error_name), Err(want.to_string()), "{name}");
                assert!(out.iter().all(|&b| b == 0xa5), "{name}: refused pack wrote");
            }
            _ => {
                result.unwrap_or_else(|e| panic!("{name}: {e}"));
                let want = hex(case.get("bytes").str());
                assert_eq!(&out[..OVERLAY_UNIFORMS_SIZE], &want[..], "{name}");
                assert!(out[OVERLAY_UNIFORMS_SIZE..].iter().all(|&b| b == 0xa5));
                packed += 1;
            }
        }
    }
    assert!(packed >= 10);
}

#[test]
fn flash_masks_match_the_vectors() {
    let doc = vectors();
    for case in doc.get("flashMask").arr() {
        let name = case.get("name").str();
        let columns = case.get("columns").num() as u32;
        let rows = case.get("rows").num() as u32;
        let mut mask = vec![false; (columns * rows) as usize];
        flash_mask(&regions(case.get("regions")), columns, rows, &mut mask).unwrap();
        let want: Vec<bool> = case
            .get("mask")
            .arr()
            .iter()
            .map(|v| v.num() != 0.0)
            .collect();
        assert_eq!(mask, want, "{name}");
    }
}

#[test]
fn schema_offsets_cover_the_block() {
    let schema = json::parse(include_str!(
        "../../../conformance/packing/overlay-uniforms.schema.json"
    ))
    .unwrap();
    assert_eq!(schema.get("size").num() as usize, OVERLAY_UNIFORMS_SIZE);
    assert_eq!(schema.get("maxRegions").num() as usize, MAX_OVERLAY_REGIONS);
    let mut end = 0;
    for field in schema.get("fields").arr() {
        let offset = field.get("offset").num() as usize;
        assert_eq!(offset, end, "fields are contiguous vec4s");
        let count = match field {
            Value::Obj(f) if f.iter().any(|(k, _)| k == "count") => field.get("count").num(),
            _ => 1.0,
        } as usize;
        assert_eq!(field.get("components").arr().len(), 4);
        end = offset + 16 * count;
    }
    assert_eq!(end, OVERLAY_UNIFORMS_SIZE);
}
