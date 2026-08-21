// Renders `Kulan/Resources/Ringtones/ring_tide.wav`, the default call ringtone.
//
//   node tools/make-ringtone.js
//
// WHY THIS IS A SCRIPT AND NOT A FILE SOMEBODY DOWNLOADED. Every tone in this app has to be ours:
// CallKit will only ring a file inside our bundle, and the moment a ringtone comes from anywhere
// else there is a licence question attached to every copy of the app. A generator settles that
// permanently, and it also means the tone can be adjusted a semitone at a time instead of being
// re-recorded.
//
// WHAT IT IS AIMING AT, measured rather than guessed. The five tones already in this folder were
// analysed first: 4.0s, 44.1kHz, mono, peaking between -1.5 and -2.5 dBFS with a mean around -15,
// and a short plucked motif of three or four notes repeating about every 1.2s between 490Hz and
// 1050Hz. That is the house style and this stays inside it.
//
// The owner also sent a recording of the ringtone he likes on his own phone (the Reflection family,
// Surge). Two things were measured off it and both are here: its envelope repeats every 0.499s,
// dead on 2 pulses a second, and it is far warmer than our five, with its energy low rather than
// bright. So this one keeps the house shape and moves it down into that warmth: it opens on a low
// A3 instead of the B4-to-C6 the others live in, and every note lands on a 0.25s or 0.5s division
// of that same 2Hz pulse.
//
// Nothing here imitates their melody. The notes are A major (A, C#, E), which is the chord the
// app's original ringtone was already built from, so the new default belongs to the same set it
// leads.
const fs = require('fs');
const path = require('path');

const RATE = 44100;
const SECONDS = 4.0;
const OUT = path.join(__dirname, '..', 'Kulan', 'Resources', 'Ringtones', 'ring_tide.wav');

const hz = midi => 440 * Math.pow(2, (midi - 69) / 12);

// [start seconds, midi note, gain, decay seconds]
//
// Two identical halves of two seconds, because CallKit loops the file and a phrase that answers
// itself is what stops a loop sounding like a loop. The second half climbs one note higher than the
// first, which is the whole idea of the tone: it does not ring at you, it rises.
const NOTES = [
  [0.00, 57, 0.50, 0.70],   // A3  the warm root, the thing the other five never do
  [0.25, 64, 0.34, 0.60],   // E4
  [0.50, 69, 0.50, 0.75],   // A4
  [0.75, 73, 0.30, 0.55],   // C#5
  [1.00, 76, 0.58, 1.15],   // E5  the lift
  [1.50, 69, 0.28, 0.70],   // A4  falling back, so the next bar has somewhere to go

  [2.00, 57, 0.50, 0.70],   // A3
  [2.25, 64, 0.34, 0.60],   // E4
  [2.50, 69, 0.50, 0.75],   // A4
  [2.75, 76, 0.32, 0.55],   // E5
  [3.00, 81, 0.60, 1.25],   // A5  the peak, an octave over the first bar's answer
  [3.50, 73, 0.26, 0.90],   // C#5 settling, and it is still ringing when the file loops
];

// A struck-bell partial set: not a plain harmonic series, because a pure one sounds like an organ.
// The 4.19 and 5.43 partials are what give it the metallic edge, and they are the quietest and the
// shortest-lived, which is what keeps it warm rather than glassy.
const PARTIALS = [
  { mult: 1.00, gain: 1.00, decay: 1.00 },
  { mult: 2.00, gain: 0.42, decay: 0.72 },
  { mult: 3.00, gain: 0.20, decay: 0.52 },
  { mult: 4.19, gain: 0.11, decay: 0.34 },
  { mult: 5.43, gain: 0.06, decay: 0.24 },
];

const n = Math.round(RATE * SECONDS);
const buf = new Float64Array(n);

for (const [start, midi, gain, decay] of NOTES) {
  const f0 = hz(midi);
  const from = Math.round(start * RATE);
  for (const p of PARTIALS) {
    const f = f0 * p.mult;
    if (f > RATE / 2.2) continue;
    const tau = decay * p.decay;
    // A tiny detune per partial. Two voices a fraction of a hertz apart beat slowly against each
    // other, which is where the movement in a struck tone comes from; dead-on partials sound
    // synthetic no matter how good the envelope is.
    const beat = 0.6 * p.mult;
    for (let i = 0; i < n - from; i++) {
      const t = i / RATE;
      if (t > tau * 5) break;
      // 4ms attack. Anything shorter is a click on a phone speaker, anything longer loses the
      // struck quality the other five have.
      const attack = Math.min(1, t / 0.004);
      const env = attack * Math.exp(-t / tau);
      buf[from + i] += gain * p.gain * env *
        (Math.sin(2 * Math.PI * f * t) + Math.sin(2 * Math.PI * (f + beat) * t)) * 0.5;
    }
  }
}

// A short pair of echoes standing in for a room. Two taps, well under the pulse, so they thicken
// the tail without smearing the next note.
const TAPS = [[0.085, 0.22], [0.170, 0.10]];
const wet = Float64Array.from(buf);
for (const [delay, level] of TAPS) {
  const d = Math.round(delay * RATE);
  for (let i = d; i < n; i++) wet[i] += buf[i - d] * level;
}

// Match the level of the five already in the folder rather than running it as hot as it will go.
// A ringtone that is louder than its neighbours is not a better ringtone, it is a complaint.
// MEASURED, not chosen: the five in this folder peak between -1.5 and -2.5 dBFS and average
// -14.4 to -16.7 dB. 0.82 is -1.7 dB, the middle of their peaks.
//
// Its MEAN lands about 2 dB hotter than theirs, and that is the pulse rather than a mistake: this
// one plays on every half beat for the whole four seconds where the others strike in clusters with
// gaps between. The peak is what a phone speaker and the system volume actually work against.
let peak = 0;
for (let i = 0; i < n; i++) peak = Math.max(peak, Math.abs(wet[i]));
const scale = 0.82 / peak;

// Fade the last 30ms to zero. The file loops, and a waveform cut mid-cycle is an audible tick on
// every repeat.
const fade = Math.round(0.030 * RATE);

const pcm = Buffer.alloc(n * 2);
for (let i = 0; i < n; i++) {
  let v = wet[i] * scale;
  if (i > n - fade) v *= (n - i) / fade;
  pcm.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(v * 32767))), i * 2);
}

const header = Buffer.alloc(44);
header.write('RIFF', 0);
header.writeUInt32LE(36 + pcm.length, 4);
header.write('WAVE', 8);
header.write('fmt ', 12);
header.writeUInt32LE(16, 16);
header.writeUInt16LE(1, 20);          // PCM
header.writeUInt16LE(1, 22);          // mono
header.writeUInt32LE(RATE, 24);
header.writeUInt32LE(RATE * 2, 28);   // byte rate
header.writeUInt16LE(2, 32);          // block align
header.writeUInt16LE(16, 34);         // bits
header.write('data', 36);
header.writeUInt32LE(pcm.length, 40);

fs.writeFileSync(OUT, Buffer.concat([header, pcm]));
console.log(`wrote ${OUT}  ${SECONDS}s  ${RATE}Hz mono  peak 0.82 (-1.7 dBFS)`);
