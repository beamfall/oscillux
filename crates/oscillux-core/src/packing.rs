// SPDX-License-Identifier: AGPL-3.0-only
//! Explicit little-endian float32 layout. Padding is zeroed; failures never partially write.

use alloc::{collections::BTreeSet, vec::Vec};

use crate::mapping::{SPECTRUM_BINS, VALUE_COUNT};

pub mod visual_uniforms;

/// [`Field::source`]: the mapped scalars, [`crate::mapping::Mapped::values`].
pub const SOURCE_MAPPED: u32 = 0;
/// [`Field::source`]: the mapped spectrum, [`crate::mapping::Mapped::spectrum`].
pub const SOURCE_SPECTRUM: u32 = 1;
/// [`Field::source`]: host values passed to [`Packer::pack`].
pub const SOURCE_HOST: u32 = 2;
/// Most fields one packer accepts.
pub const MAX_FIELDS: usize = 256;
/// Most components one field accepts.
pub const MAX_COMPONENTS: u32 = 64;

/// Copies `components` consecutive source values, as float32, into the block.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Field {
    /// `SOURCE_*`.
    pub source: u32,
    /// Index of the first source element (elements, not bytes).
    pub source_offset: u32,
    /// Number of components, 1 ..= [`MAX_COMPONENTS`].
    pub components: u32,
    /// Byte offset of the first component; a multiple of 4.
    pub offset: u32,
    /// Bytes between components; a multiple of 4, at least 4.
    pub stride: u32,
}
/// A layout or a referenced value was out of range, or the output was too short.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PackError;
/// A validated uniform block layout.
#[derive(Clone, Debug)]
pub struct Packer {
    fields: Vec<Field>,
    block_size: usize,
}
impl Packer {
    /// Validates `fields` for a `block_size`-byte block and creates a packer.
    pub fn new(fields: &[Field], block_size: usize) -> Result<Self, PackError> {
        if fields.len() > MAX_FIELDS
            || block_size == 0
            || block_size % 4 != 0
            || block_size > isize::MAX as usize
        {
            return Err(PackError);
        }
        let mut occupied = BTreeSet::new();
        for field in fields {
            if field.source > SOURCE_HOST
                || field.components == 0
                || field.components > MAX_COMPONENTS
                || field.offset % 4 != 0
                || field.stride < 4
                || field.stride % 4 != 0
            {
                return Err(PackError);
            }
            let limit = field
                .source_offset
                .checked_add(field.components)
                .ok_or(PackError)?;
            if (field.source == SOURCE_MAPPED && limit as usize > VALUE_COUNT)
                || (field.source == SOURCE_SPECTRUM && limit as usize > SPECTRUM_BINS)
            {
                return Err(PackError);
            }
            for i in 0..field.components {
                let offset = field
                    .offset
                    .checked_add(i.checked_mul(field.stride).ok_or(PackError)?)
                    .ok_or(PackError)?;
                if offset.checked_add(4).ok_or(PackError)? as usize > block_size
                    || !occupied.insert(offset)
                {
                    return Err(PackError);
                }
            }
        }
        Ok(Self {
            fields: fields.to_vec(),
            block_size,
        })
    }
    /// Block size in bytes.
    pub fn block_size(&self) -> usize {
        self.block_size
    }
    /// Writes the block to `out[..block_size]`; on failure `out` is unchanged.
    pub fn pack(
        &self,
        scalars: &[f64; VALUE_COUNT],
        spectrum: &[f32; SPECTRUM_BINS],
        host: &[f64],
        out: &mut [u8],
    ) -> Result<(), PackError> {
        if out.len() < self.block_size {
            return Err(PackError);
        }
        let source = |field: &Field, i: u32| -> Result<f32, PackError> {
            let index = (field.source_offset + i) as usize;
            let value = match field.source {
                SOURCE_MAPPED => scalars[index],
                SOURCE_SPECTRUM => spectrum[index] as f64,
                _ => *host.get(index).ok_or(PackError)?,
            };
            let narrowed = value as f32;
            if value.is_finite() && narrowed.is_finite() {
                Ok(narrowed)
            } else {
                Err(PackError)
            }
        };
        for field in &self.fields {
            for i in 0..field.components {
                source(field, i)?;
            }
        }
        out[..self.block_size].fill(0);
        for field in &self.fields {
            for i in 0..field.components {
                let value = source(field, i)?;
                let offset = (field.offset + i * field.stride) as usize;
                out[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
            }
        }
        Ok(())
    }
}
