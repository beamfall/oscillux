// SPDX-License-Identifier: AGPL-3.0-only
// The release legs' catalog: every manifest visual's catalog fields (manifest.mjs), passed through
// as data in catalogOrder, with the effect data a host lists beside them. One entry per visual:
//   id, name, tier, input, overlay, calm, blurb,
//   params       [{key: 'param0'..'param2', label, def}], all three, def the packed default
//   postFX       {bloomStrength, bloomThreshold, trailDecay, chroma, vignette, grain}
//   imageCapable, imageInput,
//   palette      {index, phase}: palette[0] and palette[2]
//   controls     the visual's param controls, as the manifest gives them
//   safety       {maxFlashHz, maxRedFlashHz, maxLuminanceDelta, textSafeZone}, measured (manifest.mjs)
import { PARAM_UNIFORMS } from './preset.mjs';

export const CATALOG_SCHEMA_VERSION = 1;

export function catalogVisuals(manifest) {
  return manifest.catalogOrder.map(id => {
    const v = manifest.byId.get(id);
    if (!v.catalog) throw new Error(`catalog: visual ${id} has no catalog fields (name, blurb, tier, input, overlay, calm)`);
    const c = v.catalog;
    const post = v.post;
    return {
      id, name: c.name, tier: c.tier, input: c.input, overlay: c.overlay, calm: c.calm, blurb: c.blurb,
      params: PARAM_UNIFORMS.map((key, i) => ({ key, label: c.paramLabels[i], def: v.params[i] })),
      postFX: {
        bloomStrength: post.bloomStrength, bloomThreshold: post.bloomThreshold, trailDecay: v.trailDecay,
        chroma: post.chroma, vignette: post.vignette, grain: post.grain,
      },
      imageCapable: c.imageCapable, imageInput: v.imageInput,
      palette: { index: v.palette[0], phase: v.palette[2] },
      controls: v.controls,
      safety: c.safety,
    };
  });
}

export function catalogDocument(manifest, release, rev) {
  return { schemaVersion: CATALOG_SCHEMA_VERSION, release, rev, license: 'AGPL-3.0-only', visuals: catalogVisuals(manifest) };
}
