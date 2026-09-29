# spectral_note
A Norns patch that outputs eight channels of midi notes with note number 36-43 where the amplitude for each band is represented as note velocity based on amplitude levels from a stereo audio signal. This midi data would be used to modulate parameters for a visual performance system. The amplitude levels would be analysed through envelope followers with variable timing for the attack and decay of sound from different fft bins.

This is all based on the engine made from the analysis code from [spectral_cc](https://github.com/khoparzi/spectral_cc)

```
-- 8-band dynamics visualizer & MIDI Note velocity sender
--
-- PAGE 1: Master Stereo In/Out Level Monitor
-- PAGE 2: 8-Band Strips UI
--
-- MIDI NOTES: 36 - 43 (Bands 1 to 8)
-- Velocity represents band peak/attack amplitude (1 - 127)
--
-- CONTROLS:
-- K3: Switch Page (1 <-> 2)
-- K2: Switch E2 Mode (Attack <-> Gain)
-- E1: Select Band (1 - 8)
-- E2: Adjust Attack (ms) OR Gain
-- E3: Adjust Decay (s)
```

Converting continuous amplitude levels to MIDI note velocities requires an onset detection / re-triggering logic. Unlike CCs (which update continuously as a stream of values), MIDI notes require explicit note_on events (with velocity 1–127) when a band strikes, followed by a note_off when the band drops back below a threshold or finishes its envelope.
