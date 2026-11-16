# dsp-edge-spec v1
# signal: kick signal plus 330 Hz sine (amplitude 0.2) at 32 kHz, 1.5 s, non-default configuration, three chunks
channels 1
config sample_rate_hz 32000
config fft_window_samples 1024
config hop_samples 256
config spectrum_bands 16
config spectrum_min_hz 50
config spectrum_max_hz 12000
config db_floor -80
config ballistics_attack_ms 5
config ballistics_release_ms 150
config rms_window_ms 100
config loudness_reference_lufs -14
config onset_band_groups 0-4,5-10,11-15
config gap_tolerance_hops 2
chunk 0 0 16000 0
chunk 516 16000 32000 0
chunk 1060 32000 48000 1
