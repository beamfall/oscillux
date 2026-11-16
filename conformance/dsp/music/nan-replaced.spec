# dsp-edge-spec v1
# signal: kick signal, 1 s; the WAV holds 0 where the replace rows inject a non-finite or beyond-f32 sample
channels 1
replace 100 nan
replace 3000 inf
replace 10000 -inf
replace 10001 1e39
replace 24575 nan
replace 24576 1e39
replace 47999 inf
